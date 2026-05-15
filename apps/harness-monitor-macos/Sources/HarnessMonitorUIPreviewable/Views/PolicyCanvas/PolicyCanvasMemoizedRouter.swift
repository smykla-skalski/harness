import CoreGraphics
import Foundation
import os

/// Memoization wrapper for `PolicyCanvasEdgeRouter`. Phase 1.3 of the tier-2
/// follow-up plan. SwiftUI invalidates `PolicyCanvasEdgeLayer.body` (and
/// `PolicyCanvasEdgeLabelLayer.body`) on every parent-state change - selection
/// flips, hover, scene-storage writes, env-key updates - and on every
/// `TimelineView(.animation)` tick when an animated edge is on screen. Without
/// memoization that means N route calls per body invocation, and a 60Hz drag
/// with 50 edges becomes 3000 route calls/sec.
///
/// The cache keys on the routing input as a single value: a `Mode` enum that
/// carries either the pinned `(source, target)` pair or the flex
/// `(sourceCandidates, targetCandidates)` pair, plus the routing context.
/// Because the inputs live inside the enum payload, there are no redundant
/// "first candidate" fallback fields and pinned calls do not allocate empty
/// candidate arrays. Movement (drag, paste, layout) changes obstacle frames,
/// which mutates the context hash and naturally invalidates affected entries.
///
/// **Cache identity invariant:** every public input read by the wrapped
/// `inner` router must be captured by the `CacheKey` derived here. The
/// endpoints and candidates are explicit; everything else lives inside
/// `PolicyCanvasRouteContext`. If you add a field that the inner router
/// reads, it MUST become part of the context's `Hashable` synthesis or
/// the cache will silently serve stale polylines. The contract test in
/// `PolicyCanvasMemoizedRouterContextContractTests.swift` enforces this
/// for every named context field by mutating one field at a time and
/// asserting the miss-rate goes to 100%.
///
/// Thread safety: state lives behind a single `OSAllocatedUnfairLock<State>`.
/// In production both render bodies run on the main actor so contention is
/// nil; the lock exists for `@unchecked Sendable` discipline.
///
/// Cache eviction: wipe-on-overflow. When `cache.count` would exceed
/// `capacity` after an insertion, the entire cache is dropped. The next
/// frame pays a single cold rebuild burst, but eviction stays O(1) instead
/// of the O(N) Array shift that an in-place LRU would impose on the hot
/// path. For a 1024-entry cap on a visual edge cache the simpler policy
/// is good enough at *steady state*: typical canvases never approach the
/// cap, and dragging past it once recovers on the next frame.
///
/// Non-steady-state corner: a long sustained drag that keeps generating
/// distinct routes (large canvas with continuous obstacle motion) will
/// thrash - fill, wipe, fill - and the operator sees periodic stutter.
/// The `cache-rebuild-overflow` OSSignposter event below is the
/// instrumentation that surfaces that case in an Instruments trace
/// before it has to be reproduced from a bug report. Two follow-ups
/// only matter once a real canvas hits the cap: bump capacity, or
/// move to a real LRU. Today the bench fixture stops at 50 edges so
/// either intervention is premature.
final class PolicyCanvasMemoizedRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  private struct CacheKey: Hashable {
    let mode: Mode
    let context: PolicyCanvasRouteContext
  }

  private enum Mode: Hashable {
    case pinned(source: CGPoint, target: CGPoint)
    case flex(sourceCandidates: [CGPoint], targetCandidates: [CGPoint])
  }

  private struct State {
    var cache: [CacheKey: PolicyCanvasEdgeRoute] = [:]
    var hits: Int = 0
    var misses: Int = 0
  }

  let inner: any PolicyCanvasEdgeRouter
  let capacity: Int
  private let state = OSAllocatedUnfairLock(initialState: State())
  private let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "policy-canvas.perf"
  )

  init(inner: any PolicyCanvasEdgeRouter, capacity: Int = 1_024) {
    precondition(capacity > 0, "PolicyCanvasMemoizedRouter capacity must be positive")
    self.inner = inner
    self.capacity = capacity
  }

  var hits: Int {
    state.withLock { $0.hits }
  }

  var misses: Int {
    state.withLock { $0.misses }
  }

  /// Drop all cached routes. Callers should invoke this when a non-input
  /// signal renders cached polylines stale (e.g. the canvas was reloaded
  /// from a document or the router default flipped at runtime).
  func invalidate() {
    state.withLock { $0.cache.removeAll() }
  }

  /// Reset hit/miss counters. Routes stay cached; only the statistics are
  /// cleared.
  func resetStatistics() {
    state.withLock {
      $0.hits = 0
      $0.misses = 0
    }
  }

  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let key = CacheKey(mode: .pinned(source: source, target: target), context: context)
    return resolve(key: key) {
      inner.route(source: source, target: target, context: context)
    }
  }

  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let key = CacheKey(
      mode: .flex(
        sourceCandidates: sourceCandidates,
        targetCandidates: targetCandidates
      ),
      context: context
    )
    return resolve(key: key) {
      inner.route(
        sourceCandidates: sourceCandidates,
        targetCandidates: targetCandidates,
        context: context
      )
    }
  }

  private func resolve(
    key: CacheKey,
    compute: () -> PolicyCanvasEdgeRoute
  ) -> PolicyCanvasEdgeRoute {
    // Fast path: take the lock once, look up, increment, and exit. The
    // compute closure cannot run under the lock (it calls back into the
    // inner router, which on the visibility-A* path itself does
    // non-trivial work) so a hit and a miss take different shapes:
    // hit -> one withLock, miss -> compute outside, second withLock to
    // record. The previous 3-call decomposition cost six atomic round
    // trips per hit instead of the two we need.
    if let hit = state.withLock({ state -> PolicyCanvasEdgeRoute? in
      if let cached = state.cache[key] {
        state.hits += 1
        return cached
      }
      return nil
    }) {
      return hit
    }
    let computed = compute()
    let overflowed: Bool = state.withLock { state in
      let didOverflow: Bool
      if state.cache[key] == nil {
        if state.cache.count >= self.capacity {
          state.cache.removeAll(keepingCapacity: true)
          didOverflow = true
        } else {
          didOverflow = false
        }
        state.cache[key] = computed
      } else {
        didOverflow = false
      }
      state.misses += 1
      return didOverflow
    }
    if overflowed {
      // Operator-visible signal in Instruments. Without this, the
      // "wipe-on-overflow caused frame stutter" failure surfaces as a
      // bug report that no log explains. The event carries the cap so
      // future readers can correlate to the bench fixture size.
      signposter.emitEvent(
        "cache-rebuild-overflow",
        "capacity=\(capacity)"
      )
    }
    return computed
  }
}
