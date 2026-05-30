import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasDisplayedRoutingTests {
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

    let maxSharedTrunkOverlap = maxSharedInteriorOverlap(across: familyRoutes.map(\.route))
    #expect(
      maxSharedTrunkOverlap < 0.001,
      """
      merge-deny failure edges carry different labels and should not share \
      interior corridors; max overlap was \(maxSharedTrunkOverlap)
      """
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
      // Each fail reason is its own transition: separate source dots and
      // separate source fanout lanes, never collapsed onto one port. The
      // target still collapses into a single top-side fan-in.
      #expect(!familyPreference.collapsesSourceTerminal)
      #expect(!familyPreference.collapsesSourceFanoutLane)
      #expect(familyPreference.collapsesTargetFanoutLane)
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

    // Separate source ports must occupy distinct source fanout lanes so the
    // dots fan out instead of stacking on one departure point.
    let familySourceLanes = mergeDenyFailureEdgeIDs.compactMap { sourceFanoutLanes[$0] }
    #expect(familySourceLanes.count == mergeDenyFailureEdgeIDs.count)
    #expect(Set(familySourceLanes).count == mergeDenyFailureEdgeIDs.count)
  }

  @Test("shared target failure families collapse top-side fanout even across different sources")
  func sharedTargetFailureFamiliesCollapseTopSideFanoutAcrossDifferentSources() {
    let target = PolicyCanvasPortEndpoint(
      nodeID: "supervisor:merge-deny", portID: "in", kind: .input)
    let edges = ["a", "b", "c"].map { suffix in
      PolicyCanvasEdge(
        id: "edge-\(suffix)",
        source: PolicyCanvasPortEndpoint(nodeID: "source-\(suffix)", portID: "fail", kind: .output),
        target: target,
        label: "evidence failure",
        condition: "checks_failed",
        pinnedPortSide: true,
        kind: .error,
        isAnimated: false
      )
    }
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
          Issue.record(
            "\(edge.id) interior segment \(segment) crosses "
              + "\(node.id) frame \(node.frame); route \(route.points)"
          )
          return
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
      fontScale: 1,
      routingHints: viewModel.routingHints
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
}

struct PolicyCanvasDisplayedRouteTestSegment {
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
