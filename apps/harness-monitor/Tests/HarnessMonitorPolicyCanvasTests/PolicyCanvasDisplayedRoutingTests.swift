import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas displayed routing")
@MainActor
struct PolicyCanvasDisplayedRoutingTests {
  @Test("default graph action routes avoid merge shapes")
  func defaultGraphActionRoutesAvoidMergeShapes() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    guard
      let mergeGroup = viewModel.group("merge"),
      let defaultRoute = routes["edge:default"],
      let mutateRoute = routes["edge:mutate"],
      let unsafeRoute = routes["edge:unsafe"]
    else {
      Issue.record("Expected merge group and action routes")
      return
    }

    let mergeNodeFrames = viewModel.nodes
      .filter { $0.groupID == mergeGroup.id }
      .map { CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize) }
    let mergeHardShapes = mergeNodeFrames + policyCanvasGroupTitleFrames([mergeGroup])
    for shape in mergeHardShapes {
      #expect(!defaultRoute.segmentsIntersect(rect: shape))
      #expect(!mutateRoute.segmentsIntersect(rect: shape))
      #expect(!unsafeRoute.segmentsIntersect(rect: shape))
    }
  }

  @Test("flex displayed routes attach to semantic visible port sides")
  func flexDisplayedRoutesAttachToSemanticVisiblePortSides() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    for edge in viewModel.edges where !edge.effectivePinnedPortSide {
      guard let route = routes[edge.id] else {
        Issue.record("Expected route for \(edge.id)")
        return
      }

      let sourceSide = policyCanvasRouteSourceSide(route)
      let sourceCandidates = viewModel.portAnchorCandidates(for: edge.source)
      if !sourceCandidates.containsSide(sourceSide) {
        let sourceContext = "\(edge.id) source side \(String(describing: sourceSide))"
        Issue.record(
          "\(sourceContext) not in \(sourceCandidates) for route \(route.points)"
        )
        return
      }
      let targetSide = policyCanvasRouteTargetSide(route)
      let targetCandidates = viewModel.portAnchorCandidates(for: edge.target)
      if !targetCandidates.containsSide(targetSide) {
        let targetContext = "\(edge.id) target side \(String(describing: targetSide))"
        Issue.record(
          "\(targetContext) not in \(targetCandidates) for route \(route.points)"
        )
        return
      }
    }
  }

  @Test("routed port visibility hides unused duplicate sides and idle empty ports")
  func routedPortVisibilityHidesUnusedDuplicateSidesAndIdleEmptyPorts() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let visibility = policyCanvasPortVisibility(
      viewModel: viewModel,
      edges: viewModel.edges,
      routes: routes
    )

    guard let evidencePass = viewModel.edges.first(where: { $0.id == "edge:evidence-pass" }) else {
      Issue.record("Expected evidence-pass edge")
      return
    }

    #expect(
      policyCanvasVisiblePortSides(for: evidencePass.source, visibility: visibility) == [
        .trailing
      ])
    #expect(
      policyCanvasVisiblePortSides(for: evidencePass.target, visibility: visibility) == [
        .leading
      ])

    let unconnectedActionInput = PolicyCanvasPortEndpoint(
      nodeID: "action:router",
      portID: "in",
      kind: .input
    )
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let markerLayout = prepared.portMarkerLayout(routes: routes, nodeIndex: prepared.nodeIndex)
    let idleVisibleSides = policyCanvasVisiblePortSides(
      for: unconnectedActionInput,
      visibility: visibility
    )
    let activeVisibleSides = policyCanvasVisiblePortSides(
      for: unconnectedActionInput,
      visibility: visibility,
      nodeIsActive: true
    )
    let draggingVisibleSides = policyCanvasVisiblePortSides(
      for: unconnectedActionInput,
      visibility: visibility,
      hasPendingEdge: true
    )

    #expect(
      idleVisibleSides.isEmpty
    )
    #expect(
      markerLayout.markers(
        for: unconnectedActionInput,
        side: .leading,
        isVisible: idleVisibleSides.contains(.leading)
      ).isEmpty
    )
    #expect(activeVisibleSides == [.leading])
    #expect(draggingVisibleSides == [.leading])
  }

  @Test("default graph displayed routes do not render diagonal or nub segments")
  func defaultGraphDisplayedRoutesDoNotRenderDiagonalOrNubSegments() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let minimumSegmentLength = PolicyCanvasVisibilityRouter.channelStep * 2

    for edge in viewModel.edges {
      guard let route = routes[edge.id] else {
        continue
      }
      for (segmentIndex, segment) in zip(route.points, route.points.dropFirst()).enumerated() {
        let (start, end) = segment
        let dx = abs(end.x - start.x)
        let dy = abs(end.y - start.y)
        let length = dx + dy
        #expect(
          dx < 0.001 || dy < 0.001,
          "\(edge.id) rendered diagonal segment \(segmentIndex): \(start) -> \(end)"
        )
        if length > 0.001 {
          #expect(
            length >= minimumSegmentLength,
            "\(edge.id) rendered short segment \(segmentIndex): \(start) -> \(end)"
          )
        }
      }
    }
  }

  @Test("default graph displayed routes do not backtrack on the same axis")
  func defaultGraphDisplayedRoutesDoNotBacktrackOnTheSameAxis() {
    let (_, routes) = defaultDisplayedRoutes()

    for (edgeID, route) in routes {
      guard route.points.count >= 3 else {
        continue
      }
      for index in 1..<(route.points.count - 1) {
        let previous = route.points[index - 1]
        let current = route.points[index]
        let next = route.points[index + 1]
        let previousDX = current.x - previous.x
        let previousDY = current.y - previous.y
        let nextDX = next.x - current.x
        let nextDY = next.y - current.y

        if abs(previousDY) < 0.001,
          abs(nextDY) < 0.001,
          abs(previousDX) > 0.001,
          abs(nextDX) > 0.001
        {
          #expect(
            previousDX * nextDX > 0,
            "\(edgeID) has horizontal backtrack at point \(index): \(route.points)"
          )
        }
        if abs(previousDX) < 0.001,
          abs(nextDX) < 0.001,
          abs(previousDY) > 0.001,
          abs(nextDY) > 0.001
        {
          #expect(
            previousDY * nextDY > 0,
            "\(edgeID) has vertical backtrack at point \(index): \(route.points)"
          )
        }
      }
    }
  }

  @Test("default graph action-family routes keep distinct source departure buses")
  func defaultGraphActionFamilyRoutesKeepDistinctSourceDepartureBuses() {
    let (_, routes) = defaultDisplayedRoutes()
    let actionTerminalEdgeIDs = ["edge:default", "edge:mutate", "edge:unsafe"]
    let actionRoutes = actionTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
    #expect(actionRoutes.count == actionTerminalEdgeIDs.count)

    let departures = actionRoutes.compactMap { entry in
      policyCanvasPrimaryDepartureBus(entry.route).map {
        (id: entry.id, axis: $0.axis, coordinate: $0.coordinate)
      }
    }
    #expect(departures.count == actionTerminalEdgeIDs.count)
    guard departures.count == actionTerminalEdgeIDs.count else {
      return
    }

    let quantized = Set(
      departures.map {
        "\($0.axis.rawValue):\(Int(($0.coordinate / PolicyCanvasLayout.gridSize).rounded()))"
      })
    #expect(
      quantized.count >= 2,
      "Action-family departures should avoid full collapse onto one source bus; departures=\(departures)"
    )
  }

  @Test("default graph only compatible edges may share interior corridors")
  func defaultGraphOnlyCompatibleEdgesMayShareInteriorCorridors() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let realizedEdges = viewModel.edges.compactMap { edge in
      routes[edge.id].map { (edge: edge, route: $0) }
    }
    #expect(realizedEdges.count == viewModel.edges.count)
    var violations: [String] = []

    for (leftIndex, leftEntry) in realizedEdges.enumerated() {
      let leftSegments = policyCanvasInteriorSegments(leftEntry.route)
      for rightEntry in realizedEdges[(leftIndex + 1)...] {
        guard leftEntry.edge.source.nodeID == rightEntry.edge.source.nodeID else {
          continue
        }
        let rightSegments = policyCanvasInteriorSegments(rightEntry.route)
        let maxSharedOverlap = leftSegments.reduce(CGFloat.zero) { overlapMax, leftSegment in
          rightSegments.reduce(overlapMax) { segmentMax, rightSegment in
            max(segmentMax, leftSegment.sharedCollinearOverlap(with: rightSegment))
          }
        }

        let mayShare =
          leftEntry.edge.target.nodeID == rightEntry.edge.target.nodeID
          && leftEntry.edge.label == rightEntry.edge.label
        if mayShare {
          continue
        }

        if maxSharedOverlap >= 0.001 {
          violations.append(
            """
            left=\(leftEntry.edge.id) label=\(leftEntry.edge.label) target=\(leftEntry.edge.target.nodeID)
            right=\(rightEntry.edge.id) label=\(rightEntry.edge.label) target=\(rightEntry.edge.target.nodeID)
            overlap=\(maxSharedOverlap)
            leftRoute=\(leftEntry.route.points)
            rightRoute=\(rightEntry.route.points)
            """
          )
        }
      }
    }
    #expect(
      violations.isEmpty,
      """
      Incompatible edges must not share interior corridors:
      \(violations.joined(separator: "\n---\n"))
      """
    )
  }

  @Test("default graph evidence failure merged wire avoids seven-bend target doglegs")
  func defaultGraphEvidenceFailureMergedWireAvoidsSevenBendTargetDoglegs() {
    let (viewModel, routes) = defaultDisplayedRoutes()

    // The four fail edges fold into one merged wire, so the seven-bend nested
    // dogleg the family used to draw collapses to a single direct approach.
    guard
      let merged = viewModel.edges.first(where: { $0.target.nodeID == "supervisor:merge-deny" }),
      let route = routes[merged.id]
    else {
      Issue.record("Expected merged evidence-failure route into merge-deny")
      return
    }

    #expect(policyCanvasRouteMetrics(route).bends <= 5)
  }

  func defaultDisplayedRoutes() -> (
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

  func policyCanvasInteriorSegments(
    _ route: PolicyCanvasEdgeRoute
  ) -> [PolicyCanvasDisplayedRouteTestSegment] {
    let segments = Array(zip(route.points, route.points.dropFirst()))
    guard segments.count > 2 else {
      return []
    }
    return segments.enumerated().compactMap { index, segment in
      guard index > 0, index < segments.count - 1 else {
        return nil
      }
      return PolicyCanvasDisplayedRouteTestSegment(start: segment.0, end: segment.1)
    }
  }

}

let mergeDenyFailureEdgeIDs = [
  "edge:evidence-fail:checks-not-green",
  "edge:evidence-fail:branch-protection-blocked",
  "edge:evidence-fail:reviewer-not-approved",
  "edge:evidence-fail:unresolved-requested-changes",
]

extension [PolicyCanvasRouteAnchorCandidate] {
  fileprivate func containsSide(_ side: PolicyCanvasPortSide?) -> Bool {
    guard let side else {
      return false
    }
    return contains { candidate in candidate.side == side }
  }
}

private struct PolicyCanvasTestDepartureBus {
  let axis: PolicyCanvasTestDepartureAxis
  let coordinate: CGFloat
}

private enum PolicyCanvasTestDepartureAxis: String {
  case horizontal
  case vertical
}

private func policyCanvasPrimaryDepartureBus(
  _ route: PolicyCanvasEdgeRoute
) -> PolicyCanvasTestDepartureBus? {
  guard route.points.count >= 4 else {
    return nil
  }
  for index in 1..<(route.points.count - 2) {
    let start = route.points[index]
    let end = route.points[index + 1]
    if abs(start.y - end.y) < 0.001, abs(start.x - end.x) > 0.001 {
      return PolicyCanvasTestDepartureBus(axis: .horizontal, coordinate: start.y)
    }
    if abs(start.x - end.x) < 0.001, abs(start.y - end.y) > 0.001 {
      return PolicyCanvasTestDepartureBus(axis: .vertical, coordinate: start.x)
    }
  }
  return nil
}
