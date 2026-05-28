import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas screenshot routing regressions")
@MainActor
struct PolicyCanvasRoutingScreenshotRegressionTests {
  @Test("default graph inter-group routes use their preferred vertical corridors")
  func defaultGraphInterGroupRoutesUseTheirPreferredVerticalCorridors() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    guard let routingHints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }

    let edgeIDs = [
      "edge:default",
      "edge:mutate",
      "edge:unsafe",
      "edge:risk-high",
      "edge:risk-low",
      "edge:risk-missing",
    ]

    for edgeID in edgeIDs {
      let edge = viewModel.edges.first(where: { $0.id == edgeID })
      #expect(edge != nil, "Expected edge for \(edgeID)")
      let route = routes[edgeID]
      #expect(route != nil, "Expected displayed route for \(edgeID)")
      let hint = routingHints.edgeHint(for: edgeID)
      #expect(hint != nil, "Expected routing hint for \(edgeID)")
      let preferredX = hint?.verticalLaneX
      #expect(
        preferredX != nil,
        "\(edgeID) should expose a preferred vertical corridor; hint \(String(describing: hint))"
      )
      let laneX = route.flatMap(policyCanvasDominantVerticalLaneCoordinate)
      #expect(
        laneX != nil,
        "\(edgeID) should expose a dominant vertical lane; route \(String(describing: route?.points))"
      )
      guard
        let edge,
        let route,
        let preferredX,
        let laneX
      else {
        continue
      }

      let tolerance = max(
        PolicyCanvasLayout.gridSize,
        viewModel.edgeLineSpacing(for: edge) * 2
      )
      #expect(
        abs(laneX - preferredX) <= tolerance,
        "\(edgeID) vertical lane \(laneX) should stay near preferred corridor \(preferredX); route \(route.points)"
      )
    }
  }

  @Test("default graph failure-family labels stay off the shared trunk")
  func defaultGraphFailureFamilyLabelsStayOffTheSharedTrunk() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let labelPositions = policyCanvasResolvedLabelPositions(
      viewModel: viewModel,
      edges: viewModel.edges,
      routes: routes,
      fontScale: 1
    )
    let familyRoutes = mergeDenyFailureEdgeIDs.compactMap { routes[$0] }
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: familyRoutes) else {
      Issue.record("Expected a shared failure-family trunk")
      return
    }

    let labelsOnTrunk = mergeDenyFailureEdgeIDs.compactMap { edgeID in
      labelPositions[edgeID]
    }.filter { position in
      abs(position.y - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.count <= 1,
      "Expected at most one failure label on the shared trunk at y=\(trunkY), saw \(labelsOnTrunk.count) with positions \(labelsOnTrunk)"
    )
  }

  private func defaultDisplayedRoutes() -> (
    viewModel: PolicyCanvasViewModel,
    routes: [String: PolicyCanvasEdgeRoute]
  ) {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    return (
      viewModel: viewModel,
      routes: policyCanvasDisplayedRoutes(
        viewModel: viewModel,
        edges: edges,
        portAnchors: viewModel.portAnchors(for: edges),
        router: PolicyCanvasVisibilityRouter()
      )
    )
  }

  private func dominantSharedHorizontalTrunkY(
    routes: [PolicyCanvasEdgeRoute]
  ) -> CGFloat? {
    let sharedSegments = routes.enumerated().flatMap { leftIndex, leftRoute in
      routes[(leftIndex + 1)...].flatMap { rightRoute -> [SharedHorizontalTrunk] in
        horizontalSegments(leftRoute).compactMap { leftSegment in
          horizontalSegments(rightRoute).compactMap { rightSegment in
            leftSegment.sharedTrunk(with: rightSegment)
          }
        }.flatMap { $0 }
      }
    }
    return sharedSegments.max(by: { $0.overlap < $1.overlap })?.y
  }

  private func horizontalSegments(_ route: PolicyCanvasEdgeRoute) -> [HorizontalSegment] {
    zip(route.points, route.points.dropFirst()).compactMap { start, end in
      HorizontalSegment(start: start, end: end)
    }
  }
}

private let mergeDenyFailureEdgeIDs = [
  "edge:evidence-fail:checks-not-green",
  "edge:evidence-fail:branch-protection-blocked",
  "edge:evidence-fail:reviewer-not-approved",
  "edge:evidence-fail:unresolved-requested-changes",
]

private struct SharedHorizontalTrunk {
  let y: CGFloat
  let overlap: CGFloat
}

private struct HorizontalSegment {
  let start: CGPoint
  let end: CGPoint

  init?(start: CGPoint, end: CGPoint) {
    guard abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
  }

  func sharedTrunk(with other: Self) -> SharedHorizontalTrunk? {
    guard abs(start.y - other.start.y) < 0.001 else {
      return nil
    }
    let overlap = max(
      0,
      min(max(start.x, end.x), max(other.start.x, other.end.x))
        - max(min(start.x, end.x), min(other.start.x, other.end.x))
    )
    guard overlap > 0.001 else {
      return nil
    }
    return SharedHorizontalTrunk(y: start.y, overlap: overlap)
  }
}
