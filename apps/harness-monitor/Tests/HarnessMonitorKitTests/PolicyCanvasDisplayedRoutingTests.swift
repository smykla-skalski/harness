import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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

      #expect(
        viewModel.portAnchorCandidates(for: edge.source).containsSide(
          policyCanvasRouteSourceSide(route)))
      #expect(
        viewModel.portAnchorCandidates(for: edge.target).containsSide(
          policyCanvasRouteTargetSide(route)))
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
        .bottom
      ])
    #expect(
      policyCanvasVisiblePortSides(for: evidencePass.target, visibility: visibility) == [
        .top
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
      idleVisibleSides == []
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

  @Test("default graph evidence failure routes avoid seven-bend target doglegs")
  func defaultGraphEvidenceFailureRoutesAvoidSevenBendTargetDoglegs() {
    let (_, routes) = defaultDisplayedRoutes()

    guard let route = routes["edge:evidence-fail:unresolved-requested-changes"] else {
      Issue.record("Expected unresolved requested changes route")
      return
    }

    #expect(policyCanvasRouteMetrics(route).bends <= 5)
    #expect(policyCanvasRouteTargetSide(route) == .top)
  }

  @Test("default graph merge-deny failure routes use top-side terminal fan-in")
  func defaultGraphMergeDenyFailureRoutesUseTopSideTerminalFanIn() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let familyRoutes = mergeDenyFailureFamilyRoutes(routes)
    #expect(familyRoutes.count == mergeDenyFailureEdgeIDs.count)

    for route in familyRoutes {
      #expect(
        policyCanvasRouteSourceSide(route.route) == .bottom,
        "\(route.id) should leave merge-evidence from the bottom side"
      )
      #expect(
        policyCanvasRouteTargetSide(route.route) == .top,
        "\(route.id) should fan into merge-deny from the top side"
      )
      let segments = Array(zip(route.route.points, route.route.points.dropFirst()))
      guard let firstSegment = segments.first else {
        Issue.record("Expected source segment for \(route.id)")
        continue
      }
      #expect(
        abs(firstSegment.0.x - firstSegment.1.x) < 0.5,
        "\(route.id) should start with a vertical source drop, not a right-side ladder segment"
      )
      guard let finalSegment = segments.last else {
        Issue.record("Expected terminal segment for \(route.id)")
        continue
      }
      #expect(
        abs(finalSegment.0.x - finalSegment.1.x) < 0.5,
        "\(route.id) should end with a short vertical terminal drop, not a side-entry dogleg"
      )
    }

    let maxSharedTrunkOverlap = familyRoutes.enumerated().reduce(CGFloat.zero) { currentMax, leftEntry in
      let (leftIndex, leftRoute) = leftEntry
      let leftSegments = policyCanvasInteriorSegments(leftRoute.route)
      let pairMax = familyRoutes[(leftIndex + 1)...].reduce(CGFloat.zero) { pairCurrentMax, rightRoute in
        let rightSegments = policyCanvasInteriorSegments(rightRoute.route)
        let overlap = leftSegments.reduce(CGFloat.zero) { overlapMax, leftSegment in
          rightSegments.reduce(overlapMax) { segmentMax, rightSegment in
            max(segmentMax, leftSegment.sharedCollinearOverlap(with: rightSegment))
          }
        }
        return max(pairCurrentMax, overlap)
      }
      return max(currentMax, pairMax)
    }
    #expect(
      maxSharedTrunkOverlap >= PolicyCanvasLayout.nodeSize.width,
      "merge-deny fan-in should keep a substantial shared interior corridor; max overlap was \(maxSharedTrunkOverlap)"
    )

    guard let mergeDeny = viewModel.node("supervisor:merge-deny") else {
      Issue.record("Expected merge-deny node")
      return
    }
    let targetFrame = CGRect(origin: mergeDeny.position, size: PolicyCanvasLayout.nodeSize)
    for route in familyRoutes {
      let targetTail = Array(route.route.points.suffix(4).dropLast())
      #expect(
        targetTail.allSatisfy { $0.y <= targetFrame.maxY + 0.5 },
        "\(route.id) should not detour beneath merge-deny before the final top-side fan-in"
      )
    }
  }

  @Test("default graph merge-deny failure family overrides pinned leading target side")
  func defaultGraphMergeDenyFailureFamilyOverridesPinnedLeadingTargetSide() {
    let (viewModel, _) = defaultDisplayedRoutes()
    let edges = viewModel.edges
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: edges)
    let portAnchors = viewModel.portAnchors(for: edges)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
    let routeLanes = viewModel.edgeRouteLanes
    let sourceFanoutLanes = viewModel.edgeSourceFanoutLanes
    let targetFanoutLanes = viewModel.edgeTargetFanoutLanes

    for edgeID in mergeDenyFailureEdgeIDs {
      guard
        let edge = edges.first(where: { $0.id == edgeID }),
        let source = portAnchors[edge.source],
        let target = portAnchors[edge.target]
      else {
        Issue.record("Expected merge-deny family edge \(edgeID)")
        return
      }
      let familyPreference = familyPreferences[edge.id, default: .none]
      #expect(familyPreference.forcedTargetSide == .top)
      #expect(familyPreference.prefersBottomSourceSideWhenTargetBelow)
      #expect(familyPreference.collapsesSourceTerminal)
      #expect(familyPreference.collapsesSourceFanoutLane)
      #expect(familyPreference.collapsesTargetFanoutLane)
      #expect(sourceFanoutLanes[edge.id] == 0)
      #expect(targetFanoutLanes[edge.id] == 0)

      let edgeTerminalSlots = terminalSlots[edge.id]
      let request = policyCanvasResolvedDisplayedRouteRequest(
        PolicyCanvasDisplayedEdgeRouteRequest(
          router: PolicyCanvasVisibilityRouter(),
          viewModel: viewModel,
          edge: edge,
          source: source,
          target: target,
          routeLane: routeLanes[edge.id, default: 0],
          sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
          targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
          sourceTerminalSlot: edgeTerminalSlots?.source ?? .single,
          targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
          familyPreference: familyPreference,
          portMarkerLayout: nil,
          lineSpacing: viewModel.edgeLineSpacing(for: edge),
          obstacles: viewModel.routingObstacles(source: source, target: target)
        )
      )

      #expect(request.sourceAnchor.side == .bottom)
      #expect(request.targetAnchor.side == .top)
      #expect(Set(request.sourceCandidates.map(\.side)) == [.bottom])
      #expect(Set(request.targetCandidates.map(\.side)) == [.top])
    }
  }

  @Test("shared target failure families collapse top-side fanout even across different sources")
  func sharedTargetFailureFamiliesCollapseTopSideFanoutAcrossDifferentSources() {
    let target = PolicyCanvasPortEndpoint(nodeID: "supervisor:merge-deny", portID: "in", kind: .input)
    let edges = [
      PolicyCanvasEdge(
        id: "edge-a",
        source: PolicyCanvasPortEndpoint(nodeID: "source-a", portID: "fail", kind: .output),
        target: target,
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      ),
      PolicyCanvasEdge(
        id: "edge-b",
        source: PolicyCanvasPortEndpoint(nodeID: "source-b", portID: "fail", kind: .output),
        target: target,
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      ),
      PolicyCanvasEdge(
        id: "edge-c",
        source: PolicyCanvasPortEndpoint(nodeID: "source-c", portID: "fail", kind: .output),
        target: target,
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      ),
    ]
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: edges)
    let targetLanes = policyCanvasTargetFanoutLaneAssignments(
      edges: edges,
      familyPreferences: familyPreferences,
      bucket: { _ in "supervisor:merge-deny|top" },
      sortKey: \.id
    )

    for edge in edges {
      #expect(familyPreferences[edge.id, default: .none].forcedTargetSide == .top)
      #expect(familyPreferences[edge.id, default: .none].collapsesTargetFanoutLane)
      #expect(targetLanes[edge.id] == 0)
    }
  }

  @Test("default graph route interiors avoid node bodies")
  func defaultGraphRouteInteriorsAvoidNodeBodies() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let nodeBodies = viewModel.nodes.map { node in
      (
        id: node.id,
        frame: CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
          .insetBy(dx: 0.5, dy: 0.5)
      )
    }

    for edge in viewModel.edges {
      guard let route = routes[edge.id] else {
        continue
      }
      for segment in policyCanvasInteriorSegments(route) {
        for node in nodeBodies where segment.intersects(node.frame) {
          #expect(Bool(false), "\(edge.id) interior segment crosses \(node.id)")
        }
      }
    }
  }

  @Test("route worker matches displayed routing semantics")
  func routeWorkerMatchesDisplayedRoutingSemantics() async {
    let (viewModel, expectedRoutes) = defaultDisplayedRoutes()
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1
    )
    let output = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(input: input)

    #expect(output.routes.keys.sorted() == expectedRoutes.keys.sorted())
    for edge in viewModel.edges {
      #expect(
        output.routes[edge.id]?.points == expectedRoutes[edge.id]?.points,
        "worker route for \(edge.id) diverged from displayed route helper"
      )
    }
    #expect(
      output.portVisibility
        == policyCanvasPortVisibility(
          viewModel: viewModel,
          edges: viewModel.edges,
          routes: expectedRoutes
        )
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

  private func policyCanvasInteriorSegments(
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

  private func mergeDenyFailureFamilyRoutes(
    _ routes: [String: PolicyCanvasEdgeRoute]
  ) -> [(id: String, route: PolicyCanvasEdgeRoute)] {
    mergeDenyFailureEdgeIDs.compactMap { edgeID in
      routes[edgeID].map { (id: edgeID, route: $0) }
    }
  }

}

private let mergeDenyFailureEdgeIDs = [
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

private struct PolicyCanvasDisplayedRouteTestSegment {
  let start: CGPoint
  let end: CGPoint

  var isHorizontal: Bool {
    abs(start.y - end.y) < 0.001
  }

  var isVertical: Bool {
    abs(start.x - end.x) < 0.001
  }

  func sharesCollinearRange(with other: Self) -> Bool {
    sharedCollinearOverlap(with: other) > 0.001
  }

  func sharedCollinearOverlap(with other: Self) -> CGFloat {
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

  func intersects(_ rect: CGRect) -> Bool {
    if isHorizontal {
      let xRange = min(start.x, end.x)...max(start.x, end.x)
      return rect.minY < start.y && rect.maxY > start.y
        && overlap(xRange, rect.minX...rect.maxX) > 0.001
    }
    if isVertical {
      let yRange = min(start.y, end.y)...max(start.y, end.y)
      return rect.minX < start.x && rect.maxX > start.x
        && overlap(yRange, rect.minY...rect.maxY) > 0.001
    }
    return false
  }

  private func overlap(_ left: ClosedRange<CGFloat>, _ right: ClosedRange<CGFloat>) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }
}
