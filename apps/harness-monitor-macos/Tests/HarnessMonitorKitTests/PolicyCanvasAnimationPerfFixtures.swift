import Foundation
import SwiftUI

@testable import HarnessMonitorUIPreviewable

/// Deterministic 50-node grid + 50-edge fixture for the animation perf gate.
/// Layout is a rough 10x5 grid of obstacle rects with edges connecting random
/// pairs. Seeded RNG keeps the layout stable across CI runs so the p99
/// number is comparable between baseline and post-memoization measurements.
struct AnimationStressFixture {
  let obstacles: [CGRect]
  let edges: [Edge]

  struct Edge {
    let source: CGPoint
    let target: CGPoint
    let lane: Int
    /// Four-side anchor candidates for the flex routing path. Order matches
    /// the canvas's `portAnchorCandidates(for:)` order so the [0] fallback
    /// pair (trailing → leading) is the natural left-to-right flow.
    let sourceCandidates: [CGPoint]
    let targetCandidates: [CGPoint]
  }

  init(seed: UInt64, edgeCount: Int) {
    var rng = SeededRNG(seed: seed)
    let columns = 10
    let rows = 5
    let nodeWidth: CGFloat = 120
    let nodeHeight: CGFloat = 64
    let gapX: CGFloat = 200
    let gapY: CGFloat = 140
    var rects: [CGRect] = []
    rects.reserveCapacity(columns * rows)
    for col in 0..<columns {
      for row in 0..<rows {
        let jitterX = CGFloat(rng.nextDouble() * 20 - 10)
        let jitterY = CGFloat(rng.nextDouble() * 20 - 10)
        rects.append(
          CGRect(
            x: CGFloat(col) * gapX + jitterX,
            y: CGFloat(row) * gapY + jitterY,
            width: nodeWidth,
            height: nodeHeight
          )
        )
      }
    }
    self.obstacles = rects

    var built: [Edge] = []
    built.reserveCapacity(edgeCount)
    for index in 0..<edgeCount {
      let sourceIdx = Int(rng.nextDouble() * Double(rects.count)) % rects.count
      var targetIdx = Int(rng.nextDouble() * Double(rects.count)) % rects.count
      if targetIdx == sourceIdx {
        targetIdx = (targetIdx + 1) % rects.count
      }
      let sourceRect = rects[sourceIdx]
      let targetRect = rects[targetIdx]
      let source = CGPoint(x: sourceRect.maxX, y: sourceRect.midY)
      let target = CGPoint(x: targetRect.minX, y: targetRect.midY)
      built.append(
        Edge(
          source: source,
          target: target,
          lane: index % 6,
          sourceCandidates: Self.sideCandidates(of: sourceRect),
          targetCandidates: Self.sideCandidates(of: targetRect)
        )
      )
    }
    self.edges = built
  }

  /// Four side-midpoints of a node rect in [trailing, leading, top, bottom]
  /// order, matching the convention used by the canvas's flex codepath. The
  /// [0] entry is trailing (right) so the degenerate fallback (every combo
  /// returns nil cost) yields trailing → leading, the natural left-to-right
  /// pair.
  private static func sideCandidates(of rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.minX, y: rect.midY),
      CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.midX, y: rect.maxY),
    ]
  }
}

/// Inner-router spy that counts every passthrough call. Used by the
/// memoization correctness tests to assert the wrapper actually caches.
final class CountingRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
  private let lock = NSLock()
  private var underlying: Int = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return underlying
  }

  func route(
    source: CGPoint,
    target: CGPoint,
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    lock.lock()
    underlying += 1
    lock.unlock()
    return PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
  }

  func route(
    sourceCandidates: [CGPoint],
    targetCandidates: [CGPoint],
    context: PolicyCanvasRouteContext
  ) -> PolicyCanvasEdgeRoute {
    lock.lock()
    underlying += 1
    lock.unlock()
    let source = sourceCandidates.first ?? .zero
    let target = targetCandidates.first ?? .zero
    return PolicyCanvasEdgeRoute(points: [source, target], labelPosition: source)
  }
}

private struct SeededRNG {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0xDEAD_BEEF_CAFE_F00D : seed
  }

  mutating func nextDouble() -> Double {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Double(state % 1_000_000) / 1_000_000
  }
}
