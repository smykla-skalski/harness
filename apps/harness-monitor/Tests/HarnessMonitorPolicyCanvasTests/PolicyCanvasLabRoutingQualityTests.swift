import CoreGraphics
import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas lab routing quality", .serialized)
struct PolicyCanvasLabRoutingQualityTests {
  @Test("multi-group sample routes stay inside a local vertical band")
  func multiGroupRoutesStayInsideLocalVerticalBand() async throws {
    let graph = try await routedLabGraph(sampleID: "multi-group")
    let hull = graphHull(nodes: graph.nodes, groups: graph.groups)
    let routeHull = routedHull(routes: graph.output.routes)
    let topEscape = max(0, hull.minY - routeHull.minY)

    #expect(
      topEscape <= PolicyCanvasLayout.nodeSize.height,
      """
      multi-group top escape should stay within one node height.
      topEscape=\(topEscape)
      hull=\(hull)
      routeHull=\(routeHull)
      """
    )
  }

  @Test("extreme sample routes stay inside a local vertical band")
  func extremeRoutesStayInsideLocalVerticalBand() async throws {
    let laidOutGraph = try laidOutLabGraph(sampleID: "extreme")
    let graph = await routedLabGraph(laidOutGraph: laidOutGraph)
    let hull = graphHull(nodes: graph.nodes, groups: graph.groups)
    let routeHull = routedHull(routes: graph.output.routes)
    let topEscape = max(0, hull.minY - routeHull.minY)
    let worstEscape = topEscapingRoute(routes: graph.output.routes, hull: hull)
    let routeAgentID = "xe:route-agent"
    let routeAgentRoute = graph.output.routes[routeAgentID]
    let routeAgentInitialRoute = graph.initialRoutes[routeAgentID]
    let routeAgentPrePostRoute = graph.routesBeforePostProcessing[routeAgentID]
    let routeAgentHint = laidOutGraph.routingHints?.edgeHint(for: routeAgentID)
    let routeAgentInitialSourceTerminal = graph.initialPortMarkerLayout.terminal(
      edgeID: routeAgentID,
      role: .source
    )
    let routeAgentInitialTargetTerminal = graph.initialPortMarkerLayout.terminal(
      edgeID: routeAgentID,
      role: .target
    )
    let routeAgentSourceTerminal = graph.portMarkerLayoutBeforePostProcessing.terminal(
      edgeID: routeAgentID,
      role: .source
    )
    let routeAgentTargetTerminal = graph.portMarkerLayoutBeforePostProcessing.terminal(
      edgeID: routeAgentID,
      role: .target
    )
    let worstEdge = worstEscape.flatMap { escapingRoute in
      laidOutGraph.edges.first { $0.id == escapingRoute.id }
    }
    let worstHint = worstEscape.flatMap { escapingRoute in
      laidOutGraph.routingHints?.edgeHint(for: escapingRoute.id)
    }
    let worstSourceFrame = worstEdge.flatMap { edge in
      laidOutGraph.nodes.first { $0.id == edge.source.nodeID }.map(policyCanvasNodeFrame)
    }
    let worstTargetFrame = worstEdge.flatMap { edge in
      laidOutGraph.nodes.first { $0.id == edge.target.nodeID }.map(policyCanvasNodeFrame)
    }
    let worstPrePostRoute = worstEscape.flatMap { escapingRoute in
      graph.routesBeforePostProcessing[escapingRoute.id]
    }
    let worstSourceTerminal = worstEscape.flatMap { escapingRoute in
      graph.portMarkerLayoutBeforePostProcessing.terminal(edgeID: escapingRoute.id, role: .source)
    }
    let worstTargetTerminal = worstEscape.flatMap { escapingRoute in
      graph.portMarkerLayoutBeforePostProcessing.terminal(edgeID: escapingRoute.id, role: .target)
    }
    let message =
      """
      topEscape=\(topEscape)
      hull=\(hull)
      routeHull=\(routeHull)
      routeAgentRoute=\(String(describing: routeAgentRoute))
      routeAgentInitialRoute=\(String(describing: routeAgentInitialRoute))
      routeAgentPrePostRoute=\(String(describing: routeAgentPrePostRoute))
      routeAgentHint=\(String(describing: routeAgentHint))
      routeAgentInitialSourceTerminal=\(String(describing: routeAgentInitialSourceTerminal))
      routeAgentInitialTargetTerminal=\(String(describing: routeAgentInitialTargetTerminal))
      routeAgentSourceTerminal=\(String(describing: routeAgentSourceTerminal))
      routeAgentTargetTerminal=\(String(describing: routeAgentTargetTerminal))
      worstEscape=\(String(describing: worstEscape))
      worstPrePostRoute=\(String(describing: worstPrePostRoute))
      worstHint=\(String(describing: worstHint))
      worstSourceFrame=\(String(describing: worstSourceFrame))
      worstTargetFrame=\(String(describing: worstTargetFrame))
      worstSourceTerminal=\(String(describing: worstSourceTerminal))
      worstTargetTerminal=\(String(describing: worstTargetTerminal))
      """
    try? message.write(
      to: URL(fileURLWithPath: "/tmp/policy-canvas-extreme-top-escape.txt"),
      atomically: true,
      encoding: .utf8
    )

    #expect(
      topEscape <= PolicyCanvasLayout.nodeSize.height,
      """
      extreme top escape should stay within one node height.
      topEscape=\(topEscape)
      hull=\(hull)
      routeHull=\(routeHull)
      worstEscape=\(String(describing: worstEscape))
      """
    )
  }

  @Test("multi-group routing is deterministic when edge order reverses")
  func multiGroupRoutingIsDeterministicAcrossEdgeOrder() async throws {
    let laidOutGraph = try laidOutLabGraph(sampleID: "multi-group")
    let forward = await routedLabGraph(laidOutGraph: laidOutGraph)
    let reversed = await routedLabGraph(laidOutGraph: laidOutGraph, reversesEdges: true)
    #expect(
      forward.orderedEdgeIDs == reversed.orderedEdgeIDs,
      """
      route build order changed when the input edge order reversed
      forward=\(forward.orderedEdgeIDs)
      reversed=\(reversed.orderedEdgeIDs)
      """
    )
    let edgeIDs = Array(Set(forward.output.routes.keys).intersection(reversed.output.routes.keys)).sorted()

    for edgeID in edgeIDs {
      let forwardRoute = try #require(forward.output.routes[edgeID])
      let reversedRoute = try #require(reversed.output.routes[edgeID])
      #expect(
        forwardRoute.points == reversedRoute.points,
        """
        route for \(edgeID) changed when the input edge order reversed
        forward=\(forwardRoute.points)
        reversed=\(reversedRoute.points)
        """
      )
    }
  }

  private func routedLabGraph(
    sampleID: String,
    reversesEdges: Bool = false
  ) async throws -> PolicyCanvasLabRoutedGraph {
    let laidOutGraph = try laidOutLabGraph(sampleID: sampleID)
    return await routedLabGraph(laidOutGraph: laidOutGraph, reversesEdges: reversesEdges)
  }

  private func laidOutLabGraph(sampleID: String) throws -> PolicyCanvasLaidOutLabGraph {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    var nodes = sample.document.nodes.map {
      policyCanvasNode($0, layout: sample.document.layout)
    }
    var edges = sample.document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: nodes)
    }
    var groups = sample.document.groups.enumerated().map { index, group in
      policyCanvasGroup(offset: index, element: group, nodes: nodes)
    }
    let result = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: nodes,
        groups: groups,
        edges: edges,
        mode: .explicitReflow(preserveManualAnchors: false),
        algorithmSelection: .harnessCurrent
      )
    )
    let routingHints = applyPolicyCanvasLayoutResult(
      result,
      nodes: &nodes,
      groups: &groups,
      centerInMinimumCanvas: true
    )
    edges = edges.map { edge in
      policyCanvasApplyingPreferredPortSides(edge, nodes: nodes)
    }
    return PolicyCanvasLaidOutLabGraph(
      nodes: nodes,
      groups: groups,
      edges: edges,
      routingHints: routingHints
    )
  }

  private func routedLabGraph(
    laidOutGraph: PolicyCanvasLaidOutLabGraph,
    reversesEdges: Bool = false
  ) async -> PolicyCanvasLabRoutedGraph {
    var edges = laidOutGraph.edges
    if reversesEdges {
      edges.reverse()
    }
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: laidOutGraph.nodes,
      groups: laidOutGraph.groups,
      edges: edges,
      fontScale: 1,
      routingHints: laidOutGraph.routingHints,
      algorithmSelection: .harnessCurrent
    )
    let preparedInput = PolicyCanvasPreparedRouteInput(input: routeInput)
    let portAnchors = preparedInput.portAnchors(nodeIndex: preparedInput.nodeIndex)
    let orderedEdgeIDs = policyCanvasRouteBuildOrder(
      edges: edges,
      portAnchors: portAnchors
    ).map(\.id)
    let routeDiagnostics = await routeDiagnostics(
      prepared: preparedInput,
      input: routeInput
    )
    let output = await PolicyCanvasRouteWorker().compute(
      input: routeInput
    )
    return PolicyCanvasLabRoutedGraph(
      nodes: laidOutGraph.nodes,
      groups: laidOutGraph.groups,
      edges: edges,
      orderedEdgeIDs: orderedEdgeIDs,
      initialRoutes: routeDiagnostics.initialRoutes,
      initialPortMarkerLayout: routeDiagnostics.initialPortMarkerLayout,
      routesBeforePostProcessing: routeDiagnostics.convergedState.routes,
      portMarkerLayoutBeforePostProcessing: routeDiagnostics.convergedState.portMarkerLayout,
      output: output
    )
  }

  private func routeDiagnostics(
    prepared: PolicyCanvasPreparedRouteInput,
    input: PolicyCanvasRouteWorkerInput
  ) async -> PolicyCanvasLabRouteDiagnostics {
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: input.algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      input.algorithmSelection.algorithmID(for: .edgeRouting)
      == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
      : algorithms.edgeRouter
    let nodeIndex = prepared.nodeIndex
    let passContext = prepared.displayedRoutePassContext(nodeIndex: nodeIndex)
    let initialRoutes = algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: prepared,
        router: selectedRouter,
        portMarkerLayout: nil,
        passContext: passContext
      )
    )
    let initialPortMarkerLayout = algorithms.portMarkerPlacement.placeMarkers(
      input: PolicyCanvasPortMarkerPlacementInput(
        prepared: prepared,
        routes: initialRoutes,
        nodeIndex: nodeIndex
      )
    )
    var state = PolicyCanvasLabRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: initialPortMarkerLayout
    )
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [state.portMarkerLayout]
    for _ in 0..<3 {
      let nextRoutes = algorithms.routeSelection.selectRoutes(
        input: PolicyCanvasRouteSelectionInput(
          prepared: prepared,
          router: selectedRouter,
          portMarkerLayout: state.portMarkerLayout,
          passContext: passContext
        )
      )
      let nextLayout = algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: prepared,
          routes: nextRoutes,
          nodeIndex: nodeIndex
        )
      )
      let nextState = PolicyCanvasLabRouteComputationState(
        routes: nextRoutes,
        portMarkerLayout: nextLayout
      )
      if nextState.portMarkerLayout == state.portMarkerLayout {
        return PolicyCanvasLabRouteDiagnostics(
          initialRoutes: initialRoutes,
          initialPortMarkerLayout: initialPortMarkerLayout,
          convergedState: nextState
        )
      }
      if seenLayouts.contains(nextState.portMarkerLayout) {
        return PolicyCanvasLabRouteDiagnostics(
          initialRoutes: initialRoutes,
          initialPortMarkerLayout: initialPortMarkerLayout,
          convergedState: PolicyCanvasLabRouteComputationState(
            routes: algorithms.routeSelection.selectRoutes(
              input: PolicyCanvasRouteSelectionInput(
                prepared: prepared,
                router: selectedRouter,
                portMarkerLayout: nextState.portMarkerLayout,
                passContext: passContext
              )
            ),
            portMarkerLayout: nextState.portMarkerLayout
          ),
        )
      }
      seenLayouts.append(nextState.portMarkerLayout)
      state = nextState
    }
    return PolicyCanvasLabRouteDiagnostics(
      initialRoutes: initialRoutes,
      initialPortMarkerLayout: initialPortMarkerLayout,
      convergedState: PolicyCanvasLabRouteComputationState(
        routes: algorithms.routeSelection.selectRoutes(
          input: PolicyCanvasRouteSelectionInput(
            prepared: prepared,
            router: selectedRouter,
            portMarkerLayout: state.portMarkerLayout,
            passContext: passContext
          )
        ),
        portMarkerLayout: state.portMarkerLayout
      ),
    )
  }

  private func graphHull(
    nodes: [PolicyCanvasNode],
    groups: [PolicyCanvasGroup]
  ) -> CGRect {
    let frames = nodes.map(policyCanvasNodeFrame) + policyCanvasGroupTitleFrames(groups)
    return frames.reduce(into: CGRect.null) { partial, frame in
      partial = partial.union(frame)
    }
  }

  private func routedHull(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> CGRect {
    routes.values.reduce(into: CGRect.null) { partial, route in
      partial = partial.union(polylineBounds(route.points))
    }
  }

  private func polylineBounds(_ points: [CGPoint]) -> CGRect {
    guard let first = points.first else {
      return .null
    }
    return points.dropFirst().reduce(into: CGRect(origin: first, size: .zero)) { partial, point in
      partial = partial.union(CGRect(origin: point, size: .zero))
    }
  }

  private func topEscapingRoute(
    routes: [String: PolicyCanvasEdgeRoute],
    hull: CGRect
  ) -> (id: String, escape: CGFloat, points: [CGPoint])? {
    routes.compactMap { id, route in
      let routeHull = polylineBounds(route.points)
      let escape = max(0, hull.minY - routeHull.minY)
      guard escape > 0 else {
        return nil
      }
      return (id: id, escape: escape, points: route.points)
    }
    .max { left, right in
      left.escape < right.escape
    }
  }
}

private struct PolicyCanvasLabRoutedGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let orderedEdgeIDs: [String]
  let initialRoutes: [String: PolicyCanvasEdgeRoute]
  let initialPortMarkerLayout: PolicyCanvasPortMarkerLayout
  let routesBeforePostProcessing: [String: PolicyCanvasEdgeRoute]
  let portMarkerLayoutBeforePostProcessing: PolicyCanvasPortMarkerLayout
  let output: PolicyCanvasRouteWorkerOutput
}

private struct PolicyCanvasLaidOutLabGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

private struct PolicyCanvasLabRouteComputationState {
  let routes: [String: PolicyCanvasEdgeRoute]
  let portMarkerLayout: PolicyCanvasPortMarkerLayout
}

private struct PolicyCanvasLabRouteDiagnostics {
  let initialRoutes: [String: PolicyCanvasEdgeRoute]
  let initialPortMarkerLayout: PolicyCanvasPortMarkerLayout
  let convergedState: PolicyCanvasLabRouteComputationState
}
