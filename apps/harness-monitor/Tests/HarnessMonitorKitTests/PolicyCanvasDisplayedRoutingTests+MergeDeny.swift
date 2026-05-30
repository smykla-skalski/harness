import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasDisplayedRoutingTests {
  @Test("default graph folds the merge-deny failure family into one top-side merged wire")
  func defaultGraphFoldsMergeDenyFailureFamilyIntoOneTopSideMergedWire() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    // The four reason-code fail edges share both endpoints, so the canvas folds
    // them into a single merged wire: one route, one clean L into merge-deny's
    // top, instead of the four cramped nested rails the old fan-in drew.
    let intoMergeDeny = viewModel.edges.filter { $0.target.nodeID == "supervisor:merge-deny" }
    #expect(intoMergeDeny.count == 1)
    guard let merged = intoMergeDeny.first, let route = routes[merged.id] else {
      Issue.record("Expected a single merged fail wire into merge-deny")
      return
    }
    #expect(merged.isMerged)
    #expect(merged.branches.count == mergeDenyFailureEdgeIDs.count)
    #expect(merged.kind == .error)
    #expect(
      policyCanvasRouteSourceSide(route) == .bottom,
      "merged wire should leave merge-evidence from the bottom side"
    )
    #expect(
      policyCanvasRouteTargetSide(route) == .top,
      "merged wire should enter merge-deny from the top side"
    )
    let segments = Array(zip(route.points, route.points.dropFirst()))
    if let firstSegment = segments.first {
      #expect(
        abs(firstSegment.0.x - firstSegment.1.x) < 0.5,
        "merged wire should start with a vertical source drop, not a right-side ladder segment"
      )
    }
    guard let finalSegment = segments.last else {
      Issue.record("Expected terminal segment for the merged wire")
      return
    }
    #expect(
      abs(finalSegment.0.x - finalSegment.1.x) < 0.5,
      "merged wire should end with a vertical terminal drop, not a side-entry dogleg"
    )
    // Bug-2 guard: the post-turn terminal drop must be at least the parallel-edge
    // spacing, so the wire never "ends immediately after its turn".
    let finalStub = abs(finalSegment.0.y - finalSegment.1.y)
    #expect(
      finalStub >= PolicyCanvasLayout.defaultEdgeLineSpacing,
      "merged wire terminal drop \(finalStub)pt is shorter than the minimum parallel spacing"
    )

    guard let mergeDeny = viewModel.node("supervisor:merge-deny") else {
      Issue.record("Expected merge-deny node")
      return
    }
    let targetFrame = CGRect(origin: mergeDeny.position, size: PolicyCanvasLayout.nodeSize)
    let targetTail = Array(route.points.suffix(4).dropLast())
    #expect(
      targetTail.allSatisfy { $0.y <= targetFrame.maxY + 0.5 },
      "merged wire should not detour beneath merge-deny before the final top-side approach"
    )
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
          let crossing = "\(edge.id) interior segment \(segment) crosses \(node.id)"
          Issue.record(
            "\(crossing) frame \(node.frame); route \(route.points)"
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
