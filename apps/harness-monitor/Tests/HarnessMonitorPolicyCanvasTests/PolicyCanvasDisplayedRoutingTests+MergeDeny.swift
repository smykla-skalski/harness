import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

extension PolicyCanvasDisplayedRoutingTests {
  @Test("default graph folds the merge-deny failure family into one clean merged wire")
  func defaultGraphFoldsMergeDenyFailureFamilyIntoOneCleanMergedWire() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    // The four reason-code fail edges share both endpoints, so the canvas folds
    // them into a single merged wire: one route into merge-deny instead of the
    // four cramped nested rails the old fan-in drew. The approach side is
    // whatever the layout makes cleanest - leading in this auto-arranged fixture,
    // top in the live graph - so the assertions are side-agnostic: what matters
    // is that the family collapses to one orthogonal error wire that arrives
    // without the bug-2 abrupt terminal stub and never detours through the body.
    let intoMergeDeny = viewModel.edges.filter { $0.target.nodeID == "supervisor:merge-deny" }
    #expect(intoMergeDeny.count == 1)
    guard let merged = intoMergeDeny.first, let route = routes[merged.id] else {
      Issue.record("Expected a single merged fail wire into merge-deny")
      return
    }
    #expect(merged.isMerged)
    #expect(merged.branches.count == mergeDenyFailureEdgeIDs.count)
    #expect(merged.kind == .error)
    let segments = Array(zip(route.points, route.points.dropFirst()))
    guard let finalSegment = segments.last else {
      Issue.record("Expected terminal segment for the merged wire")
      return
    }
    // Bug-2 guard: the final approach segment - whichever axis it runs on - must
    // be at least the parallel-edge spacing, so the wire never "ends immediately
    // after its turn" regardless of which side it enters.
    let finalApproach = max(
      abs(finalSegment.0.x - finalSegment.1.x),
      abs(finalSegment.0.y - finalSegment.1.y)
    )
    #expect(
      finalApproach >= PolicyCanvasLayout.defaultEdgeLineSpacing,
      "merged wire terminal approach \(finalApproach)pt is shorter than the minimum parallel spacing"
    )

    guard let mergeDeny = viewModel.node("supervisor:merge-deny") else {
      Issue.record("Expected merge-deny node")
      return
    }
    let targetFrame = CGRect(origin: mergeDeny.position, size: PolicyCanvasLayout.nodeSize)
    let targetTail = Array(route.points.suffix(4).dropLast())
    #expect(
      targetTail.allSatisfy { $0.y <= targetFrame.maxY + 0.5 },
      "merged wire should not detour beneath merge-deny before its final approach"
    )
  }

  @Test("multi-source failure families fan into distinct lanes across different sources")
  func sharedTargetFailureFamiliesFanIntoDistinctLanesAcrossDifferentSources() {
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

    // Three distinct source nodes into one input port are a genuine multi-source
    // fan-in. They force top-side entry so the rails stack off the node, but the
    // fan-out lane must NOT collapse: collapsed rails reach one shared lane in a
    // different order than their markers and cross. Each rail keeps its own
    // source-ordered lane instead. (Same-source parallel families fold into a
    // single merged wire on load, so they never arrive here as a family.)
    for edge in edges {
      #expect(familyPreferences[edge.id, default: .none].forcedTargetSide == .top)
      #expect(!familyPreferences[edge.id, default: .none].collapsesTargetFanoutLane)
    }
    #expect(
      Set(edges.map { targetLanes[$0.id] ?? -1 }) == [0, 1, 2],
      "each distinct-source rail gets its own fan-out lane")
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

  @Test("default helper-worker diagnostic dump")
  func defaultHelperWorkerDiagnosticDump() async throws {
    guard ProcessInfo.processInfo.environment["POLICY_CANVAS_ROUTE_DEBUG"] == "1" else {
      return
    }

    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)

    let router = PolicyCanvasVisibilityRouter()
    let helperState = helperDiagnosticState(viewModel: viewModel, router: router)
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let workerPass0 = prepared.displayedRoutes(router: router)
    let workerLayout0 = prepared.portMarkerLayout(
      routes: workerPass0,
      nodeIndex: prepared.nodeIndex
    )
    let workerPass1 = prepared.displayedRoutes(
      router: router,
      portMarkerLayout: workerLayout0
    )
    let workerLayout1 = prepared.portMarkerLayout(
      routes: workerPass1,
      nodeIndex: prepared.nodeIndex
    )
    let workerPass2 = prepared.displayedRoutes(
      router: router,
      portMarkerLayout: workerLayout1
    )
    let workerLayout2 = prepared.portMarkerLayout(
      routes: workerPass2,
      nodeIndex: prepared.nodeIndex
    )
    let workerOutput = await PolicyCanvasRouteWorker(router: router).compute(input: input)

    let payload = PolicyCanvasRouteInvestigationPayload(
      orderedEdges: helperState.orderedEdges,
      routeLanes: helperState.routeLanes,
      sourceFanoutLanes: helperState.sourceFanoutLanes,
      targetFanoutLanes: helperState.targetFanoutLanes,
      helperPass0: helperState.pass0,
      helperPass1: helperState.pass1,
      helperPass2: helperState.pass2,
      helperFinal: helperState.final,
      workerPass0: diagnosticEdges(
        routes: workerPass0,
        layout: workerLayout0,
        edgeIDs: policyCanvasDebugActionEdgeIDs
      ),
      workerPass1: diagnosticEdges(
        routes: workerPass1,
        layout: workerLayout1,
        edgeIDs: policyCanvasDebugActionEdgeIDs
      ),
      workerPass2: diagnosticEdges(
        routes: workerPass2,
        layout: workerLayout2,
        edgeIDs: policyCanvasDebugActionEdgeIDs
      ),
      workerFinal: diagnosticEdges(
        routes: workerOutput.routes,
        layout: workerOutput.portMarkerLayout,
        edgeIDs: policyCanvasDebugActionEdgeIDs
      )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(
      to: URL(fileURLWithPath: "/tmp/policy-canvas-default-helper-worker-diagnostics.json"),
      options: [.atomic]
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

private let policyCanvasDebugActionEdgeIDs = [
  "edge:default",
  "edge:mutate",
  "edge:unsafe",
  "edge:merge",
]

private struct PolicyCanvasRouteInvestigationPayload: Codable {
  let orderedEdges: [String]
  let routeLanes: [String: Int]
  let sourceFanoutLanes: [String: Int]
  let targetFanoutLanes: [String: Int]
  let helperPass0: [String: PolicyCanvasRouteInvestigationEdge]
  let helperPass1: [String: PolicyCanvasRouteInvestigationEdge]
  let helperPass2: [String: PolicyCanvasRouteInvestigationEdge]
  let helperFinal: [String: PolicyCanvasRouteInvestigationEdge]
  let workerPass0: [String: PolicyCanvasRouteInvestigationEdge]
  let workerPass1: [String: PolicyCanvasRouteInvestigationEdge]
  let workerPass2: [String: PolicyCanvasRouteInvestigationEdge]
  let workerFinal: [String: PolicyCanvasRouteInvestigationEdge]
}

private struct PolicyCanvasRouteInvestigationEdge: Codable {
  let route: [[Double]]
  let sourceTerminalSide: String?
  let targetTerminalSide: String?
  let sourceAnchorSide: String?
  let targetAnchorSide: String?
  let sourceCandidateSides: [String]
  let targetCandidateSides: [String]
  let corridorHint: PolicyCanvasRouteInvestigationHint?
}

private struct PolicyCanvasRouteInvestigationHint: Codable {
  let horizontalLaneY: Double
  let verticalLaneX: Double?
}

private struct PolicyCanvasHelperDiagnosticState {
  let orderedEdges: [String]
  let routeLanes: [String: Int]
  let sourceFanoutLanes: [String: Int]
  let targetFanoutLanes: [String: Int]
  let pass0: [String: PolicyCanvasRouteInvestigationEdge]
  let pass1: [String: PolicyCanvasRouteInvestigationEdge]
  let pass2: [String: PolicyCanvasRouteInvestigationEdge]
  let final: [String: PolicyCanvasRouteInvestigationEdge]
}

@MainActor
private func helperDiagnosticState(
  viewModel: PolicyCanvasViewModel,
  router: any PolicyCanvasEdgeRouter
) -> PolicyCanvasHelperDiagnosticState {
  let edges = viewModel.edges
  let portAnchors = viewModel.portAnchors(for: edges)
  let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
  let terminalSlots = policyCanvasRouteEndpointSlots(edges: orderedEdges)
  let nodeFramesByID = Dictionary(
    uniqueKeysWithValues: viewModel.nodes.map {
      ($0.id, CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize))
    }
  )
  let familyPreferences = policyCanvasRouteFamilyPreferences(
    edges: edges,
    nodeFramesByID: nodeFramesByID
  )
  let routeLanes = viewModel.edgeRouteLanes
  let sourceFanoutLanes = viewModel.edgeSourceFanoutLanes
  let targetFanoutLanes = viewModel.edgeTargetFanoutLanes
  let markerInput = PolicyCanvasRouteWorkerInput(
    graphGeneration: viewModel.routeComputationGeneration,
    nodes: viewModel.nodes,
    groups: viewModel.groups,
    edges: edges,
    fontScale: 1
  )
  let preparedMarkerInput = PolicyCanvasPreparedRouteInput(input: markerInput)

  let pass0 = helperDiagnosticPass(
    viewModel: viewModel,
    router: router,
    orderedEdges: orderedEdges,
    portAnchors: portAnchors,
    terminalSlots: terminalSlots,
    familyPreferences: familyPreferences,
    routeLanes: routeLanes,
    sourceFanoutLanes: sourceFanoutLanes,
    targetFanoutLanes: targetFanoutLanes,
    portMarkerLayout: nil
  )
  let layout0 = preparedMarkerInput.portMarkerLayout(
    routes: pass0.routes,
    nodeIndex: preparedMarkerInput.nodeIndex
  )
  let pass1 = helperDiagnosticPass(
    viewModel: viewModel,
    router: router,
    orderedEdges: orderedEdges,
    portAnchors: portAnchors,
    terminalSlots: terminalSlots,
    familyPreferences: familyPreferences,
    routeLanes: routeLanes,
    sourceFanoutLanes: sourceFanoutLanes,
    targetFanoutLanes: targetFanoutLanes,
    portMarkerLayout: layout0
  )
  let layout1 = preparedMarkerInput.portMarkerLayout(
    routes: pass1.routes,
    nodeIndex: preparedMarkerInput.nodeIndex
  )
  let pass2 = helperDiagnosticPass(
    viewModel: viewModel,
    router: router,
    orderedEdges: orderedEdges,
    portAnchors: portAnchors,
    terminalSlots: terminalSlots,
    familyPreferences: familyPreferences,
    routeLanes: routeLanes,
    sourceFanoutLanes: sourceFanoutLanes,
    targetFanoutLanes: targetFanoutLanes,
    portMarkerLayout: layout1
  )
  let finalRoutes = policyCanvasDisplayedRoutes(
    viewModel: viewModel,
    edges: edges,
    portAnchors: portAnchors,
    router: router
  )

  return PolicyCanvasHelperDiagnosticState(
    orderedEdges: orderedEdges.map(\.id),
    routeLanes: routeLanes,
    sourceFanoutLanes: sourceFanoutLanes,
    targetFanoutLanes: targetFanoutLanes,
    pass0: pass0.edges,
    pass1: pass1.edges,
    pass2: pass2.edges,
    final: diagnosticEdges(routes: finalRoutes, layout: layout1, edgeIDs: policyCanvasDebugActionEdgeIDs)
  )
}

private struct PolicyCanvasHelperDiagnosticPass {
  let routes: [String: PolicyCanvasEdgeRoute]
  let edges: [String: PolicyCanvasRouteInvestigationEdge]
}

@MainActor
private func helperDiagnosticPass(
  viewModel: PolicyCanvasViewModel,
  router: any PolicyCanvasEdgeRouter,
  orderedEdges: [PolicyCanvasEdge],
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint],
  terminalSlots: [String: PolicyCanvasRouteEndpointSlots],
  familyPreferences: [String: PolicyCanvasRouteFamilyPreference],
  routeLanes: [String: Int],
  sourceFanoutLanes: [String: Int],
  targetFanoutLanes: [String: Int],
  portMarkerLayout: PolicyCanvasPortMarkerLayout?
) -> PolicyCanvasHelperDiagnosticPass {
  var routes: [String: PolicyCanvasEdgeRoute] = [:]
  var diagnostics: [String: PolicyCanvasRouteInvestigationEdge] = [:]
  var previousRoutes: [PolicyCanvasDisplayedRouteClearance] = []

  for edge in orderedEdges {
    guard
      let source = portAnchors[edge.source],
      let target = portAnchors[edge.target]
    else {
      continue
    }

    let edgeTerminalSlots = terminalSlots[edge.id]
    let request = policyCanvasResolvedDisplayedRouteRequest(
      PolicyCanvasDisplayedEdgeRouteRequest(
        router: router,
        viewModel: viewModel,
        edge: edge,
        source: source,
        target: target,
        routeLane: routeLanes[edge.id, default: 0],
        sourceFanoutLane: sourceFanoutLanes[edge.id, default: 0],
        targetFanoutLane: targetFanoutLanes[edge.id, default: 0],
        sourceTerminalSlot: edgeTerminalSlots?.source ?? .single,
        targetTerminalSlot: edgeTerminalSlots?.target ?? .single,
        familyPreference: familyPreferences[edge.id, default: .none],
        portMarkerLayout: portMarkerLayout,
        lineSpacing: viewModel.edgeLineSpacing(for: edge),
        obstacles: viewModel.routingObstacles(source: source, target: target)
      )
    )
    let route = policyCanvasCollisionAwareDisplayedRoute(
      request,
      previousRoutes: previousRoutes
    )
    routes[edge.id] = route
    previousRoutes.append(
      PolicyCanvasDisplayedRouteClearance(
        edge: edge,
        corridorKey: PolicyCanvasPreparedRouteInput.policyCanvasCorridorKey(
          forRoute: route,
          hint: request.corridorHint,
          lineSpacing: request.lineSpacing
        ),
        route: route,
        minimumSpacing: policyCanvasRouteMinimumSpacing(request: request, route: route)
      )
    )

    guard policyCanvasDebugActionEdgeIDs.contains(edge.id) else {
      continue
    }
    diagnostics[edge.id] = PolicyCanvasRouteInvestigationEdge(
      route: route.points.map(policyCanvasDiagnosticPoint),
      sourceTerminalSide: portMarkerLayout?.terminal(edgeID: edge.id, role: .source).map {
        policyCanvasDiagnosticSide($0.side)
      },
      targetTerminalSide: portMarkerLayout?.terminal(edgeID: edge.id, role: .target).map {
        policyCanvasDiagnosticSide($0.side)
      },
      sourceAnchorSide: policyCanvasDiagnosticSide(request.sourceAnchor.side),
      targetAnchorSide: policyCanvasDiagnosticSide(request.targetAnchor.side),
      sourceCandidateSides: request.sourceCandidates.map { policyCanvasDiagnosticSide($0.side) },
      targetCandidateSides: request.targetCandidates.map { policyCanvasDiagnosticSide($0.side) },
      corridorHint: request.corridorHint.map {
        PolicyCanvasRouteInvestigationHint(
          horizontalLaneY: Double($0.horizontalLaneY),
          verticalLaneX: $0.verticalLaneX.map(Double.init)
        )
      }
    )
  }

  return PolicyCanvasHelperDiagnosticPass(routes: routes, edges: diagnostics)
}

private func diagnosticEdges(
  routes: [String: PolicyCanvasEdgeRoute],
  layout: PolicyCanvasPortMarkerLayout,
  edgeIDs: [String]
) -> [String: PolicyCanvasRouteInvestigationEdge] {
  Dictionary(uniqueKeysWithValues: edgeIDs.compactMap { edgeID in
    guard let route = routes[edgeID] else {
      return nil
    }
    return (
      edgeID,
      PolicyCanvasRouteInvestigationEdge(
        route: route.points.map(policyCanvasDiagnosticPoint),
        sourceTerminalSide: layout.terminal(edgeID: edgeID, role: .source).map {
          policyCanvasDiagnosticSide($0.side)
        },
        targetTerminalSide: layout.terminal(edgeID: edgeID, role: .target).map {
          policyCanvasDiagnosticSide($0.side)
        },
        sourceAnchorSide: nil,
        targetAnchorSide: nil,
        sourceCandidateSides: [],
        targetCandidateSides: [],
        corridorHint: nil
      )
    )
  })
}

private func policyCanvasDiagnosticPoint(_ point: CGPoint) -> [Double] {
  [Double(point.x), Double(point.y)]
}

private func policyCanvasDiagnosticSide(_ side: PolicyCanvasPortSide) -> String {
  String(describing: side)
}
