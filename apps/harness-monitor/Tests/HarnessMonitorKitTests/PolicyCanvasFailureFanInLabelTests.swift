import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Regression coverage for the failure fan-in into `supervisor:merge-deny`,
/// the area the live Dashboard>Policies canvas renders with four identical
/// "evidence failure" edges and several "action in" flow edges. Four defects
/// the user flagged from a screenshot walk:
///   1. a red fail bus and a blue flow bus running near-parallel within edge
///      spacing (they read as one colliding line),
///   2. a fail label landing on a vertical drop where it crosses sibling edges
///      instead of sitting on a horizontal run,
///   3. a label crammed against the turn with no clearance after the corner,
///   4. the four adjacent fan-in labels not stepping cleanly down their runs.
@Suite("Policy canvas failure fan-in label placement")
@MainActor
struct PolicyCanvasFailureFanInLabelTests {
  private let failEdgeIDs = [
    "edge:evidence-fail:checks-not-green",
    "edge:evidence-fail:branch-protection-blocked",
    "edge:evidence-fail:reviewer-not-approved",
    "edge:evidence-fail:unresolved-requested-changes",
  ]
  private let actionEdgeIDs = ["edge:default", "edge:mutate", "edge:unsafe"]

  // Issue 1: no through-flow bus may run near-parallel to the red fail fan
  // within edge spacing. Exact-collinear overlap was already separated; the gap
  // was near-parallel buses a few points apart that read as one colliding line
  // (the "evidence consensus" line in the screenshot).
  //
  // The two feeders into human:missing-merge-evidence are the hardest case: that
  // node sits on merge-deny's own row, so risk-missing has to reach it past the
  // fan band with no clear horizontal lane between the rows. The router clears
  // it by descending its bus past merge-deny's far edge instead of threading the
  // saturated band, so every non-fail edge is checked here with no exclusions.
  @Test("through-flow buses stay clear of the fail fan")
  func throughFlowBusesStayClearOfTheFailFan() {
    let scene = liveLabelScene()
    let minSeparation = PolicyCanvasLayout.defaultEdgeLineSpacing
    let meaningfulOverlap = PolicyCanvasLayout.gridSize * 3
    let throughFlowIDs =
      scene.viewModel.edges
      .filter { !failEdgeIDs.contains($0.id) }
      .map(\.id)
    var violations: [String] = []
    for redID in failEdgeIDs {
      guard let red = scene.routes[redID] else { continue }
      for blueID in throughFlowIDs {
        guard let blue = scene.routes[blueID] else { continue }
        for overlap in parallelProximities(red, blue)
        where overlap.length >= meaningfulOverlap && overlap.gap < minSeparation {
          violations.append(
            "\(redID)~\(blueID) \(overlap.axis)@\(Int(overlap.coordinate.rounded())) "
              + "gap=\(Int(overlap.gap.rounded())) len=\(Int(overlap.length.rounded()))"
          )
        }
      }
    }
    #expect(violations.isEmpty, "near-parallel red/blue buses: \(violations)")
  }

  // Issue 2: every fail label sits on a horizontal segment and does not cross
  // any other edge's polyline.
  @Test("fail labels sit on horizontal runs clear of other edges")
  func failLabelsSitOnHorizontalRunsClearOfOtherEdges() {
    let scene = liveLabelScene()
    let size = PolicyCanvasEdgeLabelMetrics(fontScale: 1).size(for: "evidence failure")
    for id in failEdgeIDs {
      guard let route = scene.routes[id], let center = scene.labels[id] else {
        Issue.record("missing route/label for \(id)")
        continue
      }
      #expect(
        !labelOnVerticalSegment(center: center, route: route), "\(id) label sits on a vertical drop"
      )
      let frame = labelFrame(center: center, size: size)
      let crossed = scene.routes.compactMap { other -> String? in
        guard other.key != id else { return nil }
        return polylineIntersects(frame, other.value.points) ? other.key : nil
      }.sorted()
      #expect(crossed.isEmpty, "\(id) label crosses \(crossed)")
    }
  }

  // Issue 3: a label on a horizontal run keeps clearance from the turn corners,
  // so it never overlaps the vertical leg it just turned off.
  @Test("fail labels keep clearance after the turn")
  func failLabelsKeepClearanceAfterTheTurn() {
    let scene = liveLabelScene()
    let size = PolicyCanvasEdgeLabelMetrics(fontScale: 1).size(for: "evidence failure")
    let minClearance = PolicyCanvasLayout.gridSize
    for id in failEdgeIDs {
      guard let route = scene.routes[id], let center = scene.labels[id] else { continue }
      let clearance = horizontalCornerClearance(center: center, size: size, route: route)
      let detail =
        "\(id) label clears its turn by only \(Int(clearance.rounded()))pt "
        + "(want >= \(Int(minClearance.rounded())))"
      #expect(clearance >= minClearance, "\(detail)")
    }
  }

  // Issue 4: the fan-in labels step monotonically down their runs and never
  // overlap each other.
  @Test("fail labels step down their runs without overlapping")
  func failLabelsStepDownTheirRunsWithoutOverlapping() {
    let scene = liveLabelScene()
    let size = PolicyCanvasEdgeLabelMetrics(fontScale: 1).size(for: "evidence failure")
    let placed = failEdgeIDs.compactMap { id in scene.labels[id].map { (id: id, center: $0) } }
      .sorted { $0.center.y < $1.center.y }
    #expect(placed.count == failEdgeIDs.count)
    for left in 0..<placed.count {
      for right in (left + 1)..<placed.count {
        let leftFrame = labelFrame(center: placed[left].center, size: size)
        let rightFrame = labelFrame(center: placed[right].center, size: size)
        #expect(
          !leftFrame.intersects(rightFrame),
          "\(placed[left].id) and \(placed[right].id) labels overlap")
      }
    }
    // Stepped: X is monotonic as the run Y descends (a staircase, not a stack).
    let xs = placed.map(\.center.x)
    let nonIncreasing = zip(xs, xs.dropFirst()).allSatisfy { $0 >= $1 - 1 }
    let nonDecreasing = zip(xs, xs.dropFirst()).allSatisfy { $0 <= $1 + 1 }
    #expect(
      nonIncreasing || nonDecreasing,
      "fan-in label Xs are not stepped: \(xs.map { Int($0.rounded()) })")
  }

  // MARK: - Scene

  struct LabelScene {
    let viewModel: PolicyCanvasViewModel
    let routes: [String: PolicyCanvasEdgeRoute]
    let labels: [String: CGPoint]
  }

  func liveLabelScene() -> LabelScene {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: viewModel.portAnchors(for: edges),
      router: PolicyCanvasVisibilityRouter()
    )
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placement = edges.compactMap { edge -> PolicyCanvasLabelPlacementRoute? in
      guard let route = routes[edge.id] else { return nil }
      let text = liveLabel(for: edge.id, fallback: edge.label)
      return PolicyCanvasLabelPlacementRoute(
        id: edge.id, label: text, route: route, size: metrics.size(for: text))
    }
    let nodeFrames =
      viewModel.nodes.map { CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize) }
      + policyCanvasGroupTitleFrames(viewModel.groups)
    let labels = policyCanvasResolvedLabelPositions(
      routes: placement,
      nodeFrames: nodeFrames,
      routeFrames: policyCanvasRouteFrames(placement))
    return LabelScene(viewModel: viewModel, routes: routes, labels: labels)
  }

  private func liveLabel(for id: String, fallback: String) -> String {
    if failEdgeIDs.contains(id) { return "evidence failure" }
    if actionEdgeIDs.contains(id) || id == "edge:merge" { return "action in" }
    return fallback
  }

  // MARK: - Geometry helpers

  struct ParallelProximity {
    let axis: String
    let coordinate: CGFloat
    let gap: CGFloat
    let length: CGFloat
  }

  func parallelProximities(
    _ left: PolicyCanvasEdgeRoute, _ right: PolicyCanvasEdgeRoute
  ) -> [ParallelProximity] {
    var out: [ParallelProximity] = []
    for (a0, a1) in zip(left.points, left.points.dropFirst()) {
      for (b0, b1) in zip(right.points, right.points.dropFirst()) {
        if abs(a0.y - a1.y) < 0.5, abs(b0.y - b1.y) < 0.5 {
          let low = max(min(a0.x, a1.x), min(b0.x, b1.x))
          let high = min(max(a0.x, a1.x), max(b0.x, b1.x))
          if high - low > 0 {
            out.append(
              .init(axis: "H", coordinate: a0.y, gap: abs(a0.y - b0.y), length: high - low))
          }
        }
        if abs(a0.x - a1.x) < 0.5, abs(b0.x - b1.x) < 0.5 {
          let low = max(min(a0.y, a1.y), min(b0.y, b1.y))
          let high = min(max(a0.y, a1.y), max(b0.y, b1.y))
          if high - low > 0 {
            out.append(
              .init(axis: "V", coordinate: a0.x, gap: abs(a0.x - b0.x), length: high - low))
          }
        }
      }
    }
    return out
  }

  func polylineIntersects(_ frame: CGRect, _ points: [CGPoint]) -> Bool {
    for (p0, p1) in zip(points, points.dropFirst()) {
      let seg = CGRect(
        x: min(p0.x, p1.x), y: min(p0.y, p1.y),
        width: abs(p1.x - p0.x), height: abs(p1.y - p0.y)
      ).insetBy(dx: -0.5, dy: -0.5)
      if seg.intersects(frame) { return true }
    }
    return false
  }

  func labelOnVerticalSegment(center: CGPoint, route: PolicyCanvasEdgeRoute) -> Bool {
    for (p0, p1) in zip(route.points, route.points.dropFirst()) {
      guard abs(p0.x - p1.x) < 0.5, abs(p0.y - p1.y) > 0.5 else { continue }
      if abs(center.x - p0.x) < 8, (min(p0.y, p1.y) - 8)...(max(p0.y, p1.y) + 8) ~= center.y {
        return true
      }
    }
    return false
  }

  // Distance from the label's near edge to the closest turn corner along the
  // horizontal run it sits on. Negative means the label spills past the corner
  // onto the vertical leg.
  func horizontalCornerClearance(
    center: CGPoint, size: CGSize, route: PolicyCanvasEdgeRoute
  ) -> CGFloat {
    var best = -CGFloat.greatestFiniteMagnitude
    for (p0, p1) in zip(route.points, route.points.dropFirst()) {
      guard abs(p0.y - p1.y) < 0.5, abs(p0.x - p1.x) > 0.5 else { continue }
      guard abs(center.y - p0.y) < size.height / 2 + 1 else { continue }
      let minX = min(p0.x, p1.x)
      let maxX = max(p0.x, p1.x)
      guard (minX - 1)...(maxX + 1) ~= center.x else { continue }
      let leftClear = (center.x - size.width / 2) - minX
      let rightClear = maxX - (center.x + size.width / 2)
      best = max(best, min(leftClear, rightClear))
    }
    return best == -CGFloat.greatestFiniteMagnitude ? 0 : best
  }

  func labelFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(
      x: center.x - size.width / 2, y: center.y - size.height / 2,
      width: size.width, height: size.height)
  }
}
