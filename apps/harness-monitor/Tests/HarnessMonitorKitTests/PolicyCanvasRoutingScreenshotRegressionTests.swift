import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas screenshot routing regressions")
@MainActor
struct PolicyCanvasRoutingScreenshotRegressionTests {
  @Test("default route uses preferred vertical corridor")
  func defaultRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:default")
  }

  @Test("mutate route uses preferred vertical corridor")
  func mutateRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:mutate")
  }

  @Test("unsafe route uses preferred vertical corridor")
  func unsafeRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:unsafe")
  }

  @Test("risk-high route uses preferred vertical corridor")
  func riskHighRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-high")
  }

  @Test("risk-low route uses preferred vertical corridor")
  func riskLowRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-low")
  }

  @Test("risk-missing route uses preferred vertical corridor")
  func riskMissingRouteUsesPreferredVerticalCorridor() {
    assertRouteUsesPreferredVerticalCorridor("edge:risk-missing")
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

  @Test("default graph action-terminal routes keep a substantial shared departure corridor")
  func defaultGraphActionTerminalRoutesKeepASubstantialSharedDepartureCorridor() {
    let (_, routes) = defaultDisplayedRoutes()
    let familyRoutes = actionTerminalRoutes(routes)
    #expect(familyRoutes.count == actionTerminalEdgeIDs.count)

    let maxSharedOverlap = maximumSharedInteriorOverlap(routes: familyRoutes.map(\.route))
    #expect(
      maxSharedOverlap >= PolicyCanvasLayout.nodeSize.width,
      "Expected action-terminal family to share a substantial transport corridor; max overlap was \(maxSharedOverlap)"
    )
  }

  @Test("default graph risk routes keep a substantial shared departure corridor")
  func defaultGraphRiskRoutesKeepASubstantialSharedDepartureCorridor() {
    let (_, routes) = defaultDisplayedRoutes()
    let familyRoutes = riskFamilyRoutes(routes)
    #expect(familyRoutes.count == riskFamilyEdgeIDs.count)

    let maxSharedOverlap = maximumSharedInteriorOverlap(routes: familyRoutes.map(\.route))
    #expect(
      maxSharedOverlap >= PolicyCanvasLayout.nodeSize.width,
      "Expected risk family to share a substantial transport corridor; max overlap was \(maxSharedOverlap)"
    )
  }

  @Test("default graph action-family duplicate labels stay off the shared departure trunk")
  func defaultGraphActionFamilyDuplicateLabelsStayOffTheSharedDepartureTrunk() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = actionTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].map {
        PolicyCanvasLabelPlacementRoute(
          id: edgeID,
          label: "action in",
          route: $0,
          size: metrics.size(for: "action in")
        )
      }
    }
    #expect(placementRoutes.count == actionTerminalEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      Issue.record("Expected a shared action-family departure trunk")
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = actionTerminalEdgeIDs.compactMap { positions[$0] }.filter {
      abs($0.y - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.count <= 1,
      "Expected at most one action-family duplicate label on the shared trunk at y=\(trunkY); saw \(labelsOnTrunk)"
    )
  }

  @Test("default graph risk labels stay off the shared departure trunk")
  func defaultGraphRiskLabelsStayOffTheSharedDepartureTrunk() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = riskFamilyEdgeIDs.compactMap {
      edgeID -> PolicyCanvasLabelPlacementRoute? in
      guard
        let route = routes[edgeID],
        let edge = viewModel.edges.first(where: { $0.id == edgeID })
      else {
        return nil
      }
      return PolicyCanvasLabelPlacementRoute(
        id: edgeID,
        label: edge.label,
        route: route,
        size: metrics.size(for: edge.label)
      )
    }
    #expect(placementRoutes.count == riskFamilyEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      Issue.record("Expected a shared risk-family departure trunk")
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = riskFamilyEdgeIDs.compactMap { positions[$0] }.filter {
      abs($0.y - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.count <= 1,
      "Expected at most one risk-family label on the shared trunk at y=\(trunkY); saw \(labelsOnTrunk)"
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

  private func assertRouteUsesPreferredVerticalCorridor(_ edgeID: String) {
    let (viewModel, routes) = defaultDisplayedRoutes()
    guard let routingHints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }

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
      return
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

  private func defaultNodeAndGroupFrames(viewModel: PolicyCanvasViewModel) -> [CGRect] {
    viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    } + policyCanvasGroupTitleFrames(viewModel.groups)
  }

  private func actionTerminalRoutes(
    _ routes: [String: PolicyCanvasEdgeRoute]
  ) -> [(id: String, route: PolicyCanvasEdgeRoute)] {
    actionTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
  }

  private func riskFamilyRoutes(
    _ routes: [String: PolicyCanvasEdgeRoute]
  ) -> [(id: String, route: PolicyCanvasEdgeRoute)] {
    riskFamilyEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
  }

  private func maximumSharedInteriorOverlap(routes: [PolicyCanvasEdgeRoute]) -> CGFloat {
    routes.enumerated().reduce(CGFloat.zero) { currentMax, leftEntry in
      let (leftIndex, leftRoute) = leftEntry
      let leftSegments = interiorSegments(leftRoute)
      let pairMax = routes[(leftIndex + 1)...].reduce(CGFloat.zero) { pairCurrentMax, rightRoute in
        let rightSegments = interiorSegments(rightRoute)
        let overlap = leftSegments.reduce(CGFloat.zero) { overlapMax, leftSegment in
          rightSegments.reduce(overlapMax) { segmentMax, rightSegment in
            max(segmentMax, leftSegment.sharedOverlap(with: rightSegment))
          }
        }
        return max(pairCurrentMax, overlap)
      }
      return max(currentMax, pairMax)
    }
  }

  private func interiorSegments(_ route: PolicyCanvasEdgeRoute) -> [DisplayedRouteSegment] {
    let segments = Array(zip(route.points, route.points.dropFirst()))
    guard segments.count > 2 else {
      return []
    }
    return segments.enumerated().compactMap { index, segment in
      guard index > 0, index < segments.count - 1 else {
        return nil
      }
      return DisplayedRouteSegment(start: segment.0, end: segment.1)
    }
  }
}

private let actionTerminalEdgeIDs = [
  "edge:default",
  "edge:mutate",
  "edge:unsafe",
]

private let riskFamilyEdgeIDs = [
  "edge:risk-high",
  "edge:risk-low",
  "edge:risk-missing",
]

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

private struct DisplayedRouteSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  func sharedOverlap(with other: Self) -> CGFloat {
    if isHorizontal, other.isHorizontal, abs(start.y - other.start.y) < 0.001 {
      return overlap(
        min(start.x, end.x)...max(start.x, end.x),
        min(other.start.x, other.end.x)...max(other.start.x, other.end.x)
      )
    }
    if isVertical, other.isVertical, abs(start.x - other.start.x) < 0.001 {
      return overlap(
        min(start.y, end.y)...max(start.y, end.y),
        min(other.start.y, other.end.y)...max(other.start.y, other.end.y)
      )
    }
    return 0
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }
}
