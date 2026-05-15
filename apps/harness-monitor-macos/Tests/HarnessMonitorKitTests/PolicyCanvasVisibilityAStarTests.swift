import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

/// Property tests for `PolicyCanvasVisibilityAStar`. Phase 2.1 of the tier-2
/// follow-up plan, closing hebert's R2 nit: the existing 20-trial random
/// graph test asserts end-to-end "got a path" but does not assert the
/// closed-set's monotonicity invariant. These properties cover three sides
/// of the invariant:
///
/// 1. **Determinism**: same inputs produce the same `(points, cost)` across
///    repeated runs. A closed-set bug that depends on `Set` iteration order
///    would surface as flaky results across runs.
///
/// 2. **Obstacle-order invariance**: shuffling the obstacle array produces
///    bit-identical results. Failures here name an algorithmic dependency
///    on input order that should not exist.
///
/// 3. **Reconstructed cost matches returned cost**: walk the polyline and
///    accumulate `length + bendPenalty × bends`. The total must equal the
///    `cost` returned alongside `points`. Failures indicate either the
///    polyline-reconstruction or the gScore tracking has drifted from the
///    other.
@Suite("Policy canvas A* closed-set properties")
struct PolicyCanvasVisibilityAStarTests {
  private static let trialCount = 30

  @Test("A* is deterministic across repeated runs on the same input")
  func deterministicAcrossRuns() {
    for trial in 0..<Self.trialCount {
      let fixture = makeFixture(seed: 0xA000 + UInt64(trial))
      let firstRun = run(fixture: fixture)
      let secondRun = run(fixture: fixture)
      let thirdRun = run(fixture: fixture)
      #expect(firstRun?.points == secondRun?.points)
      #expect(secondRun?.points == thirdRun?.points)
      #expect(firstRun?.cost == secondRun?.cost)
      #expect(secondRun?.cost == thirdRun?.cost)
    }
  }

  @Test("A* result is invariant under obstacle reordering")
  func obstacleOrderInvariant() {
    for trial in 0..<Self.trialCount {
      let fixture = makeFixture(seed: 0xB000 + UInt64(trial))
      let canonical = run(fixture: fixture)
      var generator = SystemRandomNumberGenerator()
      let shuffled = fixture.with(obstacles: fixture.obstacles.shuffled(using: &generator))
      let shuffledRun = run(fixture: shuffled)
      let reversed = fixture.with(obstacles: Array(fixture.obstacles.reversed()))
      let reversedRun = run(fixture: reversed)
      #expect(
        canonical?.points == shuffledRun?.points,
        "Obstacle shuffle changed polyline on seed \(0xB000 + UInt64(trial))"
      )
      #expect(canonical?.cost == shuffledRun?.cost)
      #expect(canonical?.points == reversedRun?.points)
      #expect(canonical?.cost == reversedRun?.cost)
    }
  }

  @Test("A* reconstructed polyline cost matches returned gScore")
  func reconstructedCostMatchesReturnedCost() {
    for trial in 0..<Self.trialCount {
      let fixture = makeFixture(seed: 0xC000 + UInt64(trial))
      guard let outcome = run(fixture: fixture) else {
        continue
      }
      let recomputed = polylineCost(outcome.points)
      let returned = outcome.cost
      // Allow a microscopic tolerance for floating-point summation order
      // since reconstruction walks left-to-right while A* accumulates per
      // expanded edge.
      #expect(
        abs(recomputed - returned) < 0.0001,
        """
        Reconstructed cost \(recomputed) diverged from returned cost \(returned) \
        on seed \(0xC000 + UInt64(trial)).
        """
      )
    }
  }

  @Test("A* never returns a polyline that re-enters the un-padded obstacles")
  func polylineSkipsObstacleInteriors() {
    // Phase 2.2: existing visibility-router test uses padded-minus-0.5 inset.
    // This case asserts the user-visible invariant directly - post-snap
    // polylines must never have a midpoint inside the ORIGINAL obstacle
    // rects, regardless of how `obstaclePadding`/`channelStep` are tuned.
    for trial in 0..<Self.trialCount {
      let fixture = makeFixture(seed: 0xD000 + UInt64(trial))
      let router = PolicyCanvasVisibilityRouter()
      let route = router.route(
        source: fixture.source,
        target: fixture.target,
        context: PolicyCanvasRouteContext(
          lane: 0,
          groups: [],
          sourceGroupID: nil,
          targetGroupID: nil,
          obstacles: fixture.obstacles
        )
      )
      let crossings = polylineCrossings(route.points, obstacles: fixture.obstacles)
      #expect(
        crossings.isEmpty,
        """
        Polyline crossed un-padded obstacles on seed \(0xD000 + UInt64(trial)): \
        \(crossings.count) crossings.
        """
      )
    }
  }

  private func run(fixture: AStarFixture) -> (points: [CGPoint], cost: CGFloat)? {
    let prepared = preparedObstacles(
      source: fixture.source,
      target: fixture.target,
      raw: fixture.obstacles
    )
    let gridXs = sortedAxisCoordinates(
      anchor1: fixture.source.x,
      anchor2: fixture.target.x,
      bounds: prepared.map { ($0.minX, $0.maxX) }
    )
    let gridYs = sortedAxisCoordinates(
      anchor1: fixture.source.y,
      anchor2: fixture.target.y,
      bounds: prepared.map { ($0.minY, $0.maxY) }
    )
    guard
      let sx = gridXs.firstIndex(of: fixture.source.x),
      let sy = gridYs.firstIndex(of: fixture.source.y),
      let tx = gridXs.firstIndex(of: fixture.target.x),
      let ty = gridYs.firstIndex(of: fixture.target.y)
    else {
      return nil
    }
    return PolicyCanvasVisibilityAStar.run(
      gridXs: gridXs,
      gridYs: gridYs,
      sourceIndex: PolicyCanvasGridIndex(x: sx, y: sy),
      targetIndex: PolicyCanvasGridIndex(x: tx, y: ty),
      obstacles: prepared
    )
  }

  private func preparedObstacles(source: CGPoint, target: CGPoint, raw: [CGRect]) -> [CGRect] {
    raw.compactMap { rect in
      let padded = rect.insetBy(
        dx: -PolicyCanvasVisibilityRouter.obstaclePadding,
        dy: -PolicyCanvasVisibilityRouter.obstaclePadding
      )
      if padded.contains(source) || padded.contains(target) {
        return nil
      }
      return padded
    }
  }

  private func sortedAxisCoordinates(
    anchor1: CGFloat,
    anchor2: CGFloat,
    bounds: [(CGFloat, CGFloat)]
  ) -> [CGFloat] {
    var values: Set<CGFloat> = [anchor1, anchor2]
    let mid = (anchor1 + anchor2) / 2
    values.insert(mid)
    for bound in bounds {
      values.insert(bound.0)
      values.insert(bound.1)
    }
    return values.sorted()
  }

  private func polylineCost(_ points: [CGPoint]) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    var total: CGFloat = 0
    var lastDirection: AxisDirection = .start
    for index in 0..<(points.count - 1) {
      let from = points[index]
      let to = points[index + 1]
      let dx = abs(to.x - from.x)
      let dy = abs(to.y - from.y)
      let here: AxisDirection = dx > dy ? .horizontal : .vertical
      total += dx + dy
      if lastDirection != .start, lastDirection != here {
        total += PolicyCanvasVisibilityRouter.bendPenalty
      }
      lastDirection = here
    }
    return total
  }

  private func polylineCrossings(_ points: [CGPoint], obstacles: [CGRect]) -> [Int] {
    var indices: [Int] = []
    guard points.count >= 2 else { return indices }
    for index in 0..<(points.count - 1) {
      let from = points[index]
      let to = points[index + 1]
      let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
      for obstacle in obstacles where obstacle.contains(mid) {
        indices.append(index)
      }
    }
    return indices
  }

  private func makeFixture(seed: UInt64) -> AStarFixture {
    var rng = AStarRNG(seed: seed)
    let nodeCount = 4 + Int(rng.nextDouble() * 8)
    let obstacles = (0..<nodeCount).map { _ in
      CGRect(
        x: CGFloat.random(in: 50...700, using: &rng),
        y: CGFloat.random(in: 50...500, using: &rng),
        width: 80 + CGFloat.random(in: 0...60, using: &rng),
        height: 40 + CGFloat.random(in: 0...40, using: &rng)
      )
    }
    return AStarFixture(
      source: CGPoint(x: 10, y: 300),
      target: CGPoint(x: 800, y: 300),
      obstacles: obstacles
    )
  }
}

private struct AStarFixture {
  let source: CGPoint
  let target: CGPoint
  let obstacles: [CGRect]

  func with(obstacles: [CGRect]) -> AStarFixture {
    AStarFixture(source: source, target: target, obstacles: obstacles)
  }
}

private enum AxisDirection {
  case start
  case horizontal
  case vertical
}

/// Same xorshift64* generator the perf-test fixture uses, repeated here to
/// keep this property suite independent of that file. Two seeds drive
/// independent trial streams without sharing state.
private struct AStarRNG: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0xCAFE_BABE_DEAD_BEEF : seed
  }

  mutating func nextDouble() -> Double {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return Double(state % 1_000_000) / 1_000_000
  }

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}
