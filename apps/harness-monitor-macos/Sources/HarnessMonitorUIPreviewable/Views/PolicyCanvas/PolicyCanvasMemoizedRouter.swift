import CoreGraphics
import Foundation
import os

/// Memoization wrapper for `PolicyCanvasEdgeRouter`. Phase 1.3 of the tier-2
/// follow-up plan. SwiftUI invalidates `PolicyCanvasEdgeLayer.body` (and
/// `PolicyCanvasEdgeLabelLayer.body`) on every parent-state change - selection
/// flips, hover, scene-storage writes, env-key updates - and on every
/// `TimelineView(.animation)` tick when an animated edge is on screen. Without
/// memoization that means N route calls per body invocation, and a 60Hz drag
/// with 50 edges becomes 3000 route calls/sec - antirez's R2 ceiling.
///
/// The cache keys on the full routing input (mode + endpoints + lane + the
/// hashable `PolicyCanvasRouteContext`) so a re-evaluation that does not move
/// any node returns the cached polyline without re-running A*. Movement
/// (drag, paste, layout) changes obstacle frames, which mutates the context
/// hash and naturally invalidates affected entries.
///
/// Thread safety: cache reads and writes are serialized through an `NSLock`.
/// In production both bodies run on the main actor so contention is nil; the
/// lock exists for `@unchecked Sendable` discipline.
///
/// Cache eviction: bounded by `capacity`; oldest entries are dropped first
/// once the cache crosses the cap. Default cap of 1024 keeps RAM negligible
/// (each `PolicyCanvasEdgeRoute` is a handful of `CGPoint`s) while covering
/// far more entries than any realistic canvas size.
final class PolicyCanvasMemoizedRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  private struct CacheKey: Hashable {
    let mode: Mode
    let source: PointKey
    let target: PointKey
    let sourceCandidates: [PointKey]
    let targetCandidates: [PointKey]
    let context: PolicyCanvasRouteContext
  }

  private enum Mode: Hashable {
    case pinned
    case flex
  }

  /// `CGPoint` is `Hashable` on macOS 26, but goes through `==` comparisons
  /// that fold floating-point representation edge cases. Wrapping the bit
  /// pattern explicitly avoids any platform-version drift in the hash and
  /// keeps the key comparison strictly bit-identical.
  private struct PointKey: Hashable {
    let xBits: UInt64
    let yBits: UInt64

    init(_ point: CGPoint) {
      self.xBits = Double(point.x).bitPattern
      self.yBits = Double(point.y).bitPattern
    }
  }

  let inner: any PolicyCanvasEdgeRouter
  let capacity: Int
  private let lock = NSLock()
  private var cache: [CacheKey: PolicyCanvasEdgeRoute] = [:]
  private var insertionOrder: [CacheKey] = []
  private let hitsCounter = OSAllocatedUnfairLock(initialState: 0)
  private let missesCounter = OSAllocatedUnfairLock(initialState: 0)

  init(inner: any PolicyCanvasEdgeRouter, capacity: Int = 1_024) {
    self.inner = inner
    self.capacity = max(16, capacity)
  }

  /// Number of cache hits since construction (or last `resetStatistics`).
  /// Useful for the hit-counter assertion in
  /// `PolicyCanvasAnimationPerfTests.memoizationReusesCachedRoute`.
  var hits: Int {
    hitsCounter.withLock { $0 }
  }

  /// Number of cache misses (calls that fell through to the inner router).
  var misses: Int {
    missesCounter.withLock { $0 }
  }

  /// Drop all cached routes. Callers should invoke this when a non-input
  /// signal renders cached polylines stale (e.g. the canvas was reloaded
  /// from a document or the router default flipped at runtime).
  func invalidate() {
    lock.lock()
    cache.removeAll()
    insertionOrder.removeAll()
    lock.unlock()
  }

  /// Reset hit/miss counters. Routes stay cached; only the statistics are
  /// cleared.
  func resetStatistics() {
    hitsCounter.withLock { $0 = 0 }
    missesCounter.withLock { $0 = 0 }
  }

  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    let key = CacheKey(
      mode: .pinned,
      source: PointKey(source),
      target: PointKey(target),
      sourceCandidates: [],
      targetCandidates: [],
      context: context
    )
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
      mode: .flex,
      source: PointKey(sourceCandidates.first ?? .zero),
      target: PointKey(targetCandidates.first ?? .zero),
      sourceCandidates: sourceCandidates.map(PointKey.init),
      targetCandidates: targetCandidates.map(PointKey.init),
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
    lock.lock()
    if let cached = cache[key] {
      lock.unlock()
      hitsCounter.withLock { $0 += 1 }
      return cached
    }
    lock.unlock()
    let computed = compute()
    lock.lock()
    if cache[key] == nil {
      cache[key] = computed
      insertionOrder.append(key)
      if insertionOrder.count > capacity {
        let evicted = insertionOrder.removeFirst()
        cache.removeValue(forKey: evicted)
      }
    }
    lock.unlock()
    missesCounter.withLock { $0 += 1 }
    return computed
  }
}
