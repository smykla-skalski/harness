import Foundation
import SwiftUI
import Testing
import os

@testable import HarnessMonitorUIPreviewable

/// Animation perf gate from the tier-2 follow-up plan. The TimelineView dash
/// march does not itself re-invoke the router, but any parent body
/// re-evaluation (a node drag, a selection change, an environment update)
/// does - and during a 60Hz drag with N animated edges that means N route
/// calls per frame. This test pins the upper bound at the budget hebert and
/// antirez named in R2: 60fps at 50 edges, p99 frame time ≤ 16.67ms.
///
/// The test is expected to fail before route memoization lands (Phase 1.3);
/// the failure message names the actual p99 so the gap is visible. The
/// number becomes the baseline that memoization has to drop below the
/// budget. Per-frame intervals are emitted on the
/// `io.harnessmonitor / policy-canvas.perf` Signposter so an Instruments
/// trace can resolve which frames blew the budget.
///
/// Bench-only: gated on `HARNESS_MONITOR_PERF_BENCH=1`. The worst-case
/// routing load is ~2 minutes wall time before memoization, which would
/// dominate every monitor:test run. The companion smoke check
/// `twentyNodeGraphPerformance` in `PolicyCanvasVisibilityRouterTests`
/// already guards against day-to-day routing regression; this gate is the
/// big number tracked between baseline and Phase 1.3.
@Suite("Policy canvas animation perf gate")
struct PolicyCanvasAnimationPerfTests {
  private static let frameBudgetSeconds: Double = 1.0 / 60.0
  private static let edgeCount = 50
  private static let frameCount = 60

  @Test(
    "50 animated edges fit a 60fps budget across 60 frames",
    .enabled(if: ProcessInfo.processInfo.environment["HARNESS_MONITOR_PERF_BENCH"] == "1")
  )
  func animationFrameBudget50Edges() {
    let fixture = AnimationStressFixture(seed: 0x5_2026_05_15, edgeCount: Self.edgeCount)
    let router = PolicyCanvasVisibilityRouter()
    let signposter = OSSignposter(
      subsystem: "io.harnessmonitor",
      category: "policy-canvas.perf"
    )
    var frameLatencies: [Double] = []
    frameLatencies.reserveCapacity(Self.frameCount)

    for frameIndex in 0..<Self.frameCount {
      let interval = signposter.beginInterval(
        "animation-frame",
        "frame=\(frameIndex)"
      )
      let frameStart = DispatchTime.now()
      for edge in fixture.edges {
        _ = router.route(
          source: edge.source,
          target: edge.target,
          context: PolicyCanvasRouteContext(
            lane: edge.lane,
            groups: [],
            sourceGroupID: nil,
            targetGroupID: nil,
            obstacles: fixture.obstacles
          )
        )
      }
      let elapsedNanos =
        DispatchTime.now().uptimeNanoseconds - frameStart.uptimeNanoseconds
      signposter.endInterval("animation-frame", interval)
      frameLatencies.append(Double(elapsedNanos) / 1_000_000_000)
    }

    let p99 = percentile(frameLatencies, fraction: 0.99)
    let median = percentile(frameLatencies, fraction: 0.5)
    #expect(
      p99 <= Self.frameBudgetSeconds,
      """
      Animation frame p99 \(format(p99))ms exceeded 16.67ms budget. \
      median=\(format(median))ms edges=\(Self.edgeCount) frames=\(Self.frameCount). \
      Memoization (Phase 1.3) is the wedge that closes this gap.
      """
    )
  }

  private func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = max(
      0,
      min(sorted.count - 1, Int((Double(sorted.count) * fraction).rounded(.down)))
    )
    return sorted[index]
  }

  private func format(_ seconds: Double) -> String {
    String(format: "%.2f", seconds * 1_000)
  }
}

/// Deterministic 50-node grid + 50-edge fixture for the animation perf gate.
/// Layout is a rough 10x5 grid of obstacle rects with edges connecting random
/// pairs. Seeded RNG keeps the layout stable across CI runs so the p99
/// number is comparable between baseline and post-memoization measurements.
private struct AnimationStressFixture {
  let obstacles: [CGRect]
  let edges: [Edge]

  struct Edge {
    let source: CGPoint
    let target: CGPoint
    let lane: Int
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
      built.append(Edge(source: source, target: target, lane: index % 6))
    }
    self.edges = built
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
