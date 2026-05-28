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
/// Cache eviction: LRU via a doubly-linked list keyed by `CacheKey`. On a
/// hit, the entry is moved to the head; on insert past capacity, the tail
/// (least recently used) is evicted. All operations are O(1). The earlier
/// wipe-on-overflow policy caused periodic stutter on long sustained drags
/// that filled the cache faster than steady-state - users saw the cache
/// thrash fill/wipe/fill. The `cache-rebuild-eviction` signpost event
/// fires per evicted entry so an Instruments trace surfaces sustained
/// pressure before it has to be reproduced from a bug report.
final class PolicyCanvasMemoizedRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  /// Cache identity for a single routing call. The invariant is the same
  /// two-halves rule documented on `PolicyCanvasRouteContext`: every input
  /// the inner router reads must live in this struct - endpoints and
  /// candidates inside `mode`, everything else inside `context`. The
  /// `PolicyCanvasMemoizedRouterContextContractTests` suite enforces both
  /// halves field-by-field. Adding an input to the inner router without
  /// extending one of these two slots silently serves stale polylines.
  private struct CacheKey: Hashable {
    let mode: Mode
    let context: PolicyCanvasRouteContext
  }

  private enum Mode: Hashable {
    case pinned(source: CGPoint, target: CGPoint)
    case flex(sourceCandidates: [CGPoint], targetCandidates: [CGPoint])
  }

  /// Linked-list node for LRU eviction. All mutations happen inside the
  /// `OSAllocatedUnfairLock<State>`, so the node is `@unchecked Sendable`
  /// in the same way the router itself is.
  private final class CacheNode: @unchecked Sendable {
    let key: CacheKey
    var value: PolicyCanvasEdgeRoute
    var prev: CacheNode?
    var next: CacheNode?

    init(key: CacheKey, value: PolicyCanvasEdgeRoute) {
      self.key = key
      self.value = value
    }
  }

  private struct State {
    var cache: [CacheKey: CacheNode] = [:]
    var head: CacheNode?
    var tail: CacheNode?
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
    state.withLock { state in
      state.cache.removeAll()
      state.head = nil
      state.tail = nil
    }
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
    // Fast path: take the lock once, look up, move-to-head on hit, and
    // exit. The compute closure cannot run under the lock (it calls back
    // into the inner router, which on the visibility-A* path itself does
    // non-trivial work) so a hit and a miss take different shapes:
    // hit -> one withLock, miss -> compute outside, second withLock to
    // record.
    if let hit = state.withLock({ state -> PolicyCanvasEdgeRoute? in
      if let node = state.cache[key] {
        state.hits += 1
        Self.touchAsMostRecent(node, state: &state)
        return node.value
      }
      return nil
    }) {
      return hit
    }
    let computed = compute()
    let evicted: Bool = state.withLock { state in
      if state.cache[key] != nil {
        // A concurrent miss already inserted this key while we computed.
        // Skip the duplicate insert and count this as a miss only.
        state.misses += 1
        return false
      }
      var didEvict = false
      if state.cache.count >= self.capacity, let tail = state.tail {
        Self.unlink(tail, state: &state)
        state.cache.removeValue(forKey: tail.key)
        didEvict = true
      }
      let node = CacheNode(key: key, value: computed)
      Self.linkAsMostRecent(node, state: &state)
      state.cache[key] = node
      state.misses += 1
      return didEvict
    }
    if evicted {
      // Operator-visible signal in Instruments. Sustained eviction
      // pressure means the working set exceeds the cap and the cache is
      // doing real work. Useful in a trace before it shows up as a
      // perceptible stutter.
      self.signposter.emitEvent(
        "cache-rebuild-eviction",
        "capacity=\(self.capacity)"
      )
    }
    return computed
  }

  private static func touchAsMostRecent(_ node: CacheNode, state: inout State) {
    guard state.head !== node else {
      return
    }
    unlink(node, state: &state)
    linkAsMostRecent(node, state: &state)
  }

  private static func linkAsMostRecent(_ node: CacheNode, state: inout State) {
    node.prev = nil
    node.next = state.head
    state.head?.prev = node
    state.head = node
    if state.tail == nil {
      state.tail = node
    }
  }

  private static func unlink(_ node: CacheNode, state: inout State) {
    let prev = node.prev
    let next = node.next
    prev?.next = next
    next?.prev = prev
    if state.head === node {
      state.head = next
    }
    if state.tail === node {
      state.tail = prev
    }
    node.prev = nil
    node.next = nil
  }
}
