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
/// Bench-only: gated on the file marker `/tmp/harness-policy-canvas-bench`.
/// xcodebuild's test runner does not reliably propagate caller env vars to
/// unit-test processes, and the bench load is ~2 minutes wall time before
/// memoization - it would dominate every monitor:test run. The companion
/// smoke check `twentyNodeGraphPerformance` in
/// `PolicyCanvasVisibilityRouterTests` already guards against day-to-day
/// routing regression; this gate is the big number tracked between
/// baseline and Phase 1.3.
///
/// To run: `touch /tmp/harness-policy-canvas-bench && mise run monitor:test
/// (with the usual XCODE_ONLY_TESTING selector)`.
@Suite("Policy canvas animation perf gate")
struct PolicyCanvasAnimationPerfTests {
  private static let frameBudgetSeconds: Double = 1.0 / 60.0
  /// 2ms-per-frame budget for the flex-anchor codepath: full 60Hz frame
  /// budget is 16.67ms, of which routing should consume at most 2ms so the
  /// remaining ~14ms is available to SwiftUI body re-evaluation, layout,
  /// and render. Per antirez R2 review note.
  private static let flexFrameBudgetSeconds: Double = 0.002
  private static let edgeCount = 50
  private static let frameCount = 60
  private static let benchMarkerPath = "/tmp/harness-policy-canvas-bench"

  private static var benchEnabled: Bool {
    FileManager.default.fileExists(atPath: benchMarkerPath)
  }

  @Test("50 animated edges fit a 60fps budget across 60 frames")
  func animationFrameBudget50Edges() {
    guard Self.benchEnabled else {
      return
    }
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

  /// Phase 1.2: worst-case flex-anchor enumeration. Every edge is unpinned
  /// so the router walks all 4x4=16 source/target combinations per call,
  /// taking the cheapest by A* cost. Without memoization or a Manhattan
  /// prune, this is the most expensive path on the canvas - antirez named
  /// 2ms per-frame total as the upper bound a 60Hz drag can tolerate
  /// before the inspector flex toggle becomes a footgun.
  ///
  /// Budget is intentionally tighter than the animation gate (2ms per
  /// frame vs 16.67ms) because flex is the *routing* layer in isolation;
  /// the remaining ~14ms of the frame budget belongs to SwiftUI body
  /// re-evaluation, layout, and render.
  @Test("50 flex-anchor edges fit 2ms per frame across 60 frames")
  func flexAnchorBudget50Edges() {
    guard Self.benchEnabled else {
      return
    }
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
        "flex-frame",
        "frame=\(frameIndex)"
      )
      let frameStart = DispatchTime.now()
      for edge in fixture.edges {
        _ = router.route(
          sourceCandidates: edge.sourceCandidates,
          targetCandidates: edge.targetCandidates,
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
      signposter.endInterval("flex-frame", interval)
      frameLatencies.append(Double(elapsedNanos) / 1_000_000_000)
    }

    let p99 = percentile(frameLatencies, fraction: 0.99)
    let median = percentile(frameLatencies, fraction: 0.5)
    #expect(
      p99 <= Self.flexFrameBudgetSeconds,
      """
      Flex-anchor frame p99 \(format(p99))ms exceeded 2ms budget. \
      median=\(format(median))ms edges=\(Self.edgeCount) frames=\(Self.frameCount). \
      Memoization (Phase 1.3) plus an optional Manhattan-distance prune on \
      flex combos are the two remediation levers.
      """
    )
  }

  /// Phase 1.3 correctness check: a memoized router must route a given key
  /// exactly once and serve every subsequent call with the cached polyline.
  /// Always runs (not bench-gated) because the assertion is correctness, not
  /// performance: the contract that distinguishes "real cache" from "no
  /// cache" must not silently regress.
  ///
  /// Test shape: a counting inner router records every passthrough. The
  /// memoized wrapper is invoked 100 times with the same key, then once
  /// with a different key. The counter should read 2 (one miss per unique
  /// key); the wrapper's `hits` counter should read 99 (the repeated
  /// invocations after the first miss).
  @Test("Memoized router reuses cached routes for identical inputs")
  func memoizationReusesCachedRoute() {
    let counter = CountingRouter()
    let memoized = PolicyCanvasMemoizedRouter(inner: counter)
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: []
    )
    let source = CGPoint(x: 10, y: 100)
    let target = CGPoint(x: 200, y: 100)

    for _ in 0..<100 {
      _ = memoized.route(source: source, target: target, context: context)
    }
    // One additional unique key forces a second miss.
    _ = memoized.route(
      source: CGPoint(x: 11, y: 100),
      target: target,
      context: context
    )

    #expect(counter.count == 2, "Inner router invoked \(counter.count) times, expected 2")
    #expect(memoized.hits == 99, "Cache hits \(memoized.hits), expected 99")
    #expect(memoized.misses == 2, "Cache misses \(memoized.misses), expected 2")
  }

  @Test("Memoized router invalidate() clears cached routes")
  func memoizationInvalidateClearsCache() {
    let counter = CountingRouter()
    let memoized = PolicyCanvasMemoizedRouter(inner: counter)
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: []
    )
    let source = CGPoint(x: 0, y: 0)
    let target = CGPoint(x: 100, y: 0)

    _ = memoized.route(source: source, target: target, context: context)
    _ = memoized.route(source: source, target: target, context: context)
    #expect(counter.count == 1)

    memoized.invalidate()
    _ = memoized.route(source: source, target: target, context: context)
    #expect(counter.count == 2, "Invalidate should force a fresh miss")
  }

  @Test("Memoized router treats flex and pinned modes as distinct keys")
  func memoizationDistinguishesFlexFromPinned() {
    let counter = CountingRouter()
    let memoized = PolicyCanvasMemoizedRouter(inner: counter)
    let context = PolicyCanvasRouteContext(
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil,
      obstacles: []
    )
    let source = CGPoint(x: 0, y: 0)
    let target = CGPoint(x: 100, y: 0)

    _ = memoized.route(source: source, target: target, context: context)
    _ = memoized.route(
      sourceCandidates: [source],
      targetCandidates: [target],
      context: context
    )
    #expect(counter.count == 2, "Pinned and flex modes must not share a cache slot")
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
private final class CountingRouter: PolicyCanvasEdgeRouter, @unchecked Sendable {
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
