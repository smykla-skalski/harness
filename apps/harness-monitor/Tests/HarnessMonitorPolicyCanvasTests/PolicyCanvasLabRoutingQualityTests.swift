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

  private func routeBodyHits(
    route: PolicyCanvasEdgeRoute,
    edge: PolicyCanvasEdge,
    nodes: [PolicyCanvasNode],
    nodeFrames: [String: CGRect],
    titleFrames: [(PolicyCanvasGroup, CGRect)]
  ) -> [String] {
    let endpointIDs = Set([edge.source.nodeID, edge.target.nodeID])
    if let nodeHit = nodes.first(where: { node in
      !endpointIDs.contains(node.id) && route.segmentsIntersect(rect: nodeFrames[node.id] ?? .null)
    }) {
      return ["crosses node \(nodeHit.id)"]
    }
    if let titleHit = titleFrames.first(where: { _, frame in
      route.segmentsIntersect(rect: frame.insetBy(dx: 0.5, dy: 0.5))
    }) {
      return ["crosses group title \(titleHit.0.id)"]
    }
    return []
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

  @Test("extreme sample duplicate failure labels do not overlap")
  func extremeSampleDuplicateFailureLabelsDoNotOverlap() async throws {
    let laidOutGraph = try laidOutLabGraph(sampleID: "extreme")
    let graph = await routedLabGraph(laidOutGraph: laidOutGraph)
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: graph.nodes,
      groups: graph.groups,
      edges: graph.edges,
      fontScale: 1,
      routingHints: laidOutGraph.routingHints,
      algorithmSelection: .referenceRouting
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: routeInput)
    let labelPositions = prepared.resolvedLabelPositions(routes: graph.output.routes)
    let labelOverlaps = policyCanvasLabLabelOverlapPairs(
      edges: graph.edges,
      labelPositions: labelPositions
    )

    #expect(
      labelOverlaps.isEmpty,
      """
      extreme sample labels should not overlap
      overlaps=\(labelOverlaps)
      """
    )
  }

  @Test("extreme sample merge resumes avoid incompatible target-corridor sharing")
  func extremeSampleMergeResumesAvoidIncompatibleTargetCorridorSharing() async throws {
    let laidOutGraph = try laidOutLabGraph(sampleID: "extreme")
    let graph = await routedLabGraph(laidOutGraph: laidOutGraph)
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: graph.nodes,
      groups: graph.groups,
      edges: graph.edges,
      fontScale: 1,
      routingHints: laidOutGraph.routingHints,
      algorithmSelection: .referenceRouting
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: routeInput)
    let overlap = try policyCanvasLabIncompatibleInteriorOverlap(
      leftID: "xe:wait-merge",
      rightID: "xe:event-merge",
      routes: graph.output.routes,
      edges: graph.edges,
      routingHints: laidOutGraph.routingHints,
      prepared: prepared
    )

    #expect(
      overlap <= PolicyCanvasLayout.gridSize,
      """
      extreme merge resume routes still share an incompatible target corridor
      overlap=\(overlap)
      waitPrePost=\(String(describing: graph.routesBeforePostProcessing["xe:wait-merge"]?.points))
      wait=\(String(describing: graph.output.routes["xe:wait-merge"]?.points))
      eventPrePost=\(String(describing: graph.routesBeforePostProcessing["xe:event-merge"]?.points))
      event=\(String(describing: graph.output.routes["xe:event-merge"]?.points))
      """
    )
  }

  @Test("extreme sample review routes avoid incompatible interior corridor sharing")
  func extremeSampleReviewRoutesAvoidIncompatibleInteriorCorridorSharing() async throws {
    let laidOutGraph = try laidOutLabGraph(sampleID: "extreme")
    let graph = await routedLabGraph(laidOutGraph: laidOutGraph)
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: graph.nodes,
      groups: graph.groups,
      edges: graph.edges,
      fontScale: 1,
      routingHints: laidOutGraph.routingHints,
      algorithmSelection: .referenceRouting
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: routeInput)
    let overlap = try policyCanvasLabIncompatibleInteriorOverlap(
      leftID: "xe:route-review",
      rightID: "xe:route-verify",
      routes: graph.output.routes,
      edges: graph.edges,
      routingHints: laidOutGraph.routingHints,
      prepared: prepared
    )

    #expect(
      overlap <= PolicyCanvasLayout.gridSize,
      """
      extreme review routes still share an incompatible interior corridor
      overlap=\(overlap)
      reviewPrePost=\(String(describing: graph.routesBeforePostProcessing["xe:route-review"]?.points))
      review=\(String(describing: graph.output.routes["xe:route-review"]?.points))
      verifyPrePost=\(String(describing: graph.routesBeforePostProcessing["xe:route-verify"]?.points))
      verify=\(String(describing: graph.output.routes["xe:route-verify"]?.points))
      """
    )
  }

  @Test("extreme sample live routes avoid node and group title bodies")
  @MainActor
  func extremeSampleLiveRoutesAvoidNodeAndGroupTitleBodies() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: scene.viewModel.nodes.map { node in
        (node.id, policyCanvasNodeFrame(node).insetBy(dx: 0.5, dy: 0.5))
      }
    )
    let titleFrames = Array(zip(scene.viewModel.groups, policyCanvasGroupTitleFrames(scene.viewModel.groups)))
    var hits: [String] = []

    for edge in scene.edges {
      guard let route = scene.output.routes[edge.id] else {
        hits.append("\(edge.id): missing route")
        continue
      }
      let endpointIDs = Set([edge.source.nodeID, edge.target.nodeID])
      if let nodeHit = scene.viewModel.nodes.first(where: { node in
        !endpointIDs.contains(node.id) && route.segmentsIntersect(rect: nodeFrames[node.id] ?? .null)
      }) {
        hits.append("\(edge.id) crosses node \(nodeHit.id); route \(route.points)")
        continue
      }
      if let titleHit = titleFrames.first(where: { _, frame in
        route.segmentsIntersect(rect: frame.insetBy(dx: 0.5, dy: 0.5))
      }) {
        hits.append("\(edge.id) crosses group title \(titleHit.0.id); route \(route.points)")
      }
    }

    #expect(
      hits.isEmpty,
      """
      extreme live routes still pass through node or group-title bodies
      hits=\(hits)
      """
    )
  }

  @Test("extreme sample live routes attach to semantic visible port sides")
  @MainActor
  func extremeSampleLiveRoutesAttachToSemanticVisiblePortSides() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    var violations: [String] = []

    for edge in scene.edges where !edge.effectivePinnedPortSide {
      guard let route = scene.output.routes[edge.id] else {
        violations.append("\(edge.id): missing route")
        continue
      }
      let sourceSide = policyCanvasRouteSourceSide(route)
      let sourceCandidates = scene.viewModel.portAnchorCandidates(for: edge.source)
      if !sourceCandidates.contains(where: { $0.side == sourceSide }) {
        violations.append(
          "\(edge.id) source side \(String(describing: sourceSide)) not in \(sourceCandidates); route \(route.points)"
        )
      }
      let targetSide = policyCanvasRouteTargetSide(route)
      let targetCandidates = scene.viewModel.portAnchorCandidates(for: edge.target)
      if !targetCandidates.contains(where: { $0.side == targetSide }) {
        violations.append(
          "\(edge.id) target side \(String(describing: targetSide)) not in \(targetCandidates); route \(route.points)"
        )
      }
    }

    #expect(
      violations.isEmpty,
      """
      extreme live routes still attach to impossible semantic port sides
      violations=\(violations)
      """
    )
  }

  @Test("extreme route-agent keeps a rightward source departure")
  @MainActor
  func extremeSampleRouteAgentKeepsARightwardSourceDeparture() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let route = try #require(scene.output.routes["xe:route-agent"])

    #expect(
      policyCanvasRouteSourceSide(route) == .trailing,
      "route-agent should leave x-route to the right; route=\(route.points)"
    )
  }

  @Test("extreme route-verify keeps a rightward source departure")
  @MainActor
  func extremeSampleRouteVerifyKeepsARightwardSourceDeparture() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let route = try #require(scene.output.routes["xe:route-verify"])

    #expect(
      policyCanvasRouteSourceSide(route) == .trailing,
      "route-verify should leave x-route to the right; route=\(route.points)"
    )
  }

  @Test("extreme sample live route terminals land on visible marker dots")
  @MainActor
  func extremeSampleLiveRouteTerminalsLandOnVisibleMarkerDots() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let scenario = PolicyCanvasTerminalScenario(
      viewModel: scene.viewModel,
      edges: scene.edges,
      routes: scene.output.routes
    )
    let assertions = PolicyCanvasRoutingTerminalTests()

    assertions.assertMarkerOffsets(
      scenario: scenario,
      markerLayout: scene.output.portMarkerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .source,
        endpoint: \.source,
        routePoint: { $0.points.first },
        routeSide: policyCanvasRouteSourceSide,
        label: "source"
      )
    )
    assertions.assertMarkerOffsets(
      scenario: scenario,
      markerLayout: scene.output.portMarkerLayout,
      assertion: PolicyCanvasTerminalAssertion(
        role: .target,
        endpoint: \.target,
        routePoint: { $0.points.last },
        routeSide: policyCanvasRouteTargetSide,
        label: "target"
      )
    )
  }

  @Test("extreme sample live connected endpoints remain visible")
  @MainActor
  func extremeSampleLiveConnectedEndpointsRemainVisible() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let invisibleEndpoints = scene.edges.flatMap { edge -> [String] in
      [
        (label: "source", endpoint: edge.source),
        (label: "target", endpoint: edge.target),
      ].compactMap { entry in
        let sides = policyCanvasVisiblePortSides(
          for: entry.endpoint,
          visibility: scene.output.portVisibility
        )
        guard sides.isEmpty else {
          return nil
        }
        return "\(edge.id) \(entry.label)=\(entry.endpoint)"
      }
    }

    #expect(
      invisibleEndpoints.isEmpty,
      """
      connected endpoints lost visible sides in the live extreme sample
      invisibleEndpoints=\(invisibleEndpoints)
      """
    )
  }

  @Test("extreme sample live routes avoid real X-crossings")
  @MainActor
  func extremeSampleLiveRoutesAvoidRealXCrossings() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let realized = scene.edges.compactMap { edge in
      scene.output.routes[edge.id].map { (id: edge.id, route: $0) }
    }
    var crossings: [String] = []

    for leftIndex in realized.indices {
      for rightIndex in realized.index(after: leftIndex)..<realized.endIndex
      where policyCanvasRoutesProperlyCross(realized[leftIndex].route, realized[rightIndex].route) {
        crossings.append("\(realized[leftIndex].id) x \(realized[rightIndex].id)")
      }
    }

    #expect(
      crossings.isEmpty,
      """
      extreme live routes still have real X-crossings
      crossings=\(crossings)
      """
    )
  }

  @Test("extreme x-human fan-in post-processing does not introduce body hits")
  @MainActor
  func extremeSampleLiveXHumanFanInPostProcessingDoesNotIntroduceBodyHits() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let edgeIDs = ["xe:sw-draft", "xe:missing-0", "xe:missing-1", "xe:missing-2"]
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: scene.viewModel.nodes.map { node in
        (node.id, policyCanvasNodeFrame(node).insetBy(dx: 0.5, dy: 0.5))
      }
    )
    let titleFrames = Array(zip(scene.viewModel.groups, policyCanvasGroupTitleFrames(scene.viewModel.groups)))
    let regressions = edgeIDs.compactMap { edgeID -> String? in
      guard
        let edge = scene.edges.first(where: { $0.id == edgeID }),
        let before = scene.routesBeforePostProcessing[edgeID],
        let after = scene.output.routes[edgeID]
      else {
        return "\(edgeID): missing route state"
      }
      let beforeHits = routeBodyHits(
        route: before,
        edge: edge,
        nodes: scene.viewModel.nodes,
        nodeFrames: nodeFrames,
        titleFrames: titleFrames
      )
      let afterHits = routeBodyHits(
        route: after,
        edge: edge,
        nodes: scene.viewModel.nodes,
        nodeFrames: nodeFrames,
        titleFrames: titleFrames
      )
      guard beforeHits.isEmpty, !afterHits.isEmpty else {
        return nil
      }
      return "\(edgeID) before=\(before.points) after=\(after.points) hits=\(afterHits)"
    }

    #expect(
      regressions.isEmpty,
      """
      x-human fan-in post-processing introduced node/group-title hits
      regressions=\(regressions)
      """
    )
  }

  @Test("extreme residual body hits are not introduced by post-processing")
  @MainActor
  func extremeSampleLiveResidualBodyHitsAreNotIntroducedByPostProcessing() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let edgeIDs = ["xe:missing-0", "xe:missing-2", "xe:route-verify"]
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: scene.viewModel.nodes.map { node in
        (node.id, policyCanvasNodeFrame(node).insetBy(dx: 0.5, dy: 0.5))
      }
    )
    let titleFrames = Array(zip(scene.viewModel.groups, policyCanvasGroupTitleFrames(scene.viewModel.groups)))
    let regressions = edgeIDs.compactMap { edgeID -> String? in
      guard
        let edge = scene.edges.first(where: { $0.id == edgeID }),
        let before = scene.routesBeforePostProcessing[edgeID],
        let after = scene.output.routes[edgeID]
      else {
        return "\(edgeID): missing route state"
      }
      let beforeHits = routeBodyHits(
        route: before,
        edge: edge,
        nodes: scene.viewModel.nodes,
        nodeFrames: nodeFrames,
        titleFrames: titleFrames
      )
      let afterHits = routeBodyHits(
        route: after,
        edge: edge,
        nodes: scene.viewModel.nodes,
        nodeFrames: nodeFrames,
        titleFrames: titleFrames
      )
      guard beforeHits.isEmpty, !afterHits.isEmpty else {
        return nil
      }
      return "\(edgeID) before=\(before.points) after=\(after.points) hits=\(afterHits)"
    }

    #expect(
      regressions.isEmpty,
      """
      residual live body hits were introduced during post-processing
      regressions=\(regressions)
      """
    )
  }

  @Test("extreme residual missing rails avoid local body blockers")
  @MainActor
  func extremeSampleLiveResidualMissingRailsAvoidLocalBodyBlockers() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let edgeIDs = ["xe:missing-0", "xe:missing-2"]
    let nodeFrames = Dictionary(
      uniqueKeysWithValues: scene.viewModel.nodes.map { node in
        (node.id, policyCanvasNodeFrame(node).insetBy(dx: 0.5, dy: 0.5))
      }
    )
    let titleFrames = Array(zip(scene.viewModel.groups, policyCanvasGroupTitleFrames(scene.viewModel.groups)))
    let hits = edgeIDs.compactMap { edgeID -> String? in
      guard
        let edge = scene.edges.first(where: { $0.id == edgeID }),
        let route = scene.output.routes[edgeID]
      else {
        return "\(edgeID): missing route"
      }
      let routeHits = routeBodyHits(
        route: route,
        edge: edge,
        nodes: scene.viewModel.nodes,
        nodeFrames: nodeFrames,
        titleFrames: titleFrames
      )
      guard !routeHits.isEmpty else {
        return nil
      }
      return "\(edgeID) route=\(route.points) hits=\(routeHits)"
    }

    #expect(
      hits.isEmpty,
      """
      residual missing rails still hit local body blockers
      hits=\(hits)
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

  @MainActor
  private func liveRoutedLabScene(
    sampleID: String
  ) async throws -> PolicyCanvasLiveLabScene {
    let sample = try #require(PolicyCanvasLabSamples.sample(id: sampleID))
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: sample.document, simulation: nil, audit: nil)
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    let edges = viewModel.edges
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1,
      routingHints: viewModel.routingHints,
      algorithmSelection: .referenceRouting
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: routeInput)
    let diagnostics = await routeDiagnostics(prepared: prepared, input: routeInput)
    let output = await PolicyCanvasRouteWorker().compute(input: routeInput)
    return PolicyCanvasLiveLabScene(
      viewModel: viewModel,
      edges: edges,
      initialRoutes: diagnostics.initialRoutes,
      initialPortMarkerLayout: diagnostics.initialPortMarkerLayout,
      routesBeforePostProcessing: diagnostics.convergedState.routes,
      portMarkerLayoutBeforePostProcessing: diagnostics.convergedState.portMarkerLayout,
      output: output
    )
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
        algorithmSelection: .referenceRouting
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
      algorithmSelection: .referenceRouting
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

@MainActor
private struct PolicyCanvasLiveLabScene {
  let viewModel: PolicyCanvasViewModel
  let edges: [PolicyCanvasEdge]
  let initialRoutes: [String: PolicyCanvasEdgeRoute]
  let initialPortMarkerLayout: PolicyCanvasPortMarkerLayout
  let routesBeforePostProcessing: [String: PolicyCanvasEdgeRoute]
  let portMarkerLayoutBeforePostProcessing: PolicyCanvasPortMarkerLayout
  let output: PolicyCanvasRouteWorkerOutput
}

private func policyCanvasRoutesProperlyCross(
  _ left: PolicyCanvasEdgeRoute,
  _ right: PolicyCanvasEdgeRoute
) -> Bool {
  for (a0, a1) in zip(left.points, left.points.dropFirst()) {
    for (b0, b1) in zip(right.points, right.points.dropFirst())
    where policyCanvasSegmentsProperlyCross(a0, a1, b0, b1) {
      return true
    }
  }
  return false
}

private func policyCanvasSegmentsProperlyCross(
  _ a0: CGPoint,
  _ a1: CGPoint,
  _ b0: CGPoint,
  _ b1: CGPoint
) -> Bool {
  let tolerance: CGFloat = 0.5
  let aHorizontal = abs(a0.y - a1.y) < tolerance
  let aVertical = abs(a0.x - a1.x) < tolerance
  let bHorizontal = abs(b0.y - b1.y) < tolerance
  let bVertical = abs(b0.x - b1.x) < tolerance
  if aHorizontal, bVertical {
    let crossX = b0.x
    let crossY = a0.y
    return crossX > min(a0.x, a1.x) + tolerance
      && crossX < max(a0.x, a1.x) - tolerance
      && crossY > min(b0.y, b1.y) + tolerance
      && crossY < max(b0.y, b1.y) - tolerance
  }
  if aVertical, bHorizontal {
    return policyCanvasSegmentsProperlyCross(b0, b1, a0, a1)
  }
  return false
}

private func policyCanvasLabLabelOverlapPairs(
  edges: [PolicyCanvasEdge],
  labelPositions: [String: CGPoint]
) -> [(leftID: String, rightID: String)] {
  let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
  let labelled = edges.compactMap { edge -> (id: String, frame: CGRect)? in
    guard !edge.label.isEmpty, let position = labelPositions[edge.id] else {
      return nil
    }
    return (edge.id, metrics.frame(for: edge.label, center: position))
  }
  var overlaps: [(leftID: String, rightID: String)] = []
  for leftIndex in labelled.indices {
    for rightIndex in labelled.index(after: leftIndex)..<labelled.endIndex {
      if labelled[leftIndex].frame.intersects(labelled[rightIndex].frame) {
        overlaps.append((labelled[leftIndex].id, labelled[rightIndex].id))
      }
    }
  }
  return overlaps
}

private func policyCanvasLabIncompatibleInteriorOverlap(
  leftID: String,
  rightID: String,
  routes: [String: PolicyCanvasEdgeRoute],
  edges: [PolicyCanvasEdge],
  routingHints: PolicyCanvasLayoutRoutingHints?,
  prepared: PolicyCanvasPreparedRouteInput
) throws -> CGFloat {
  let edgeByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
  let nodeIndex = prepared.nodeIndex
  let leftEdge = try #require(edgeByID[leftID])
  let rightEdge = try #require(edgeByID[rightID])
  let leftRoute = try #require(routes[leftID])
  let rightRoute = try #require(routes[rightID])
  let leftLineSpacing = prepared.edgeLineSpacing(for: leftEdge, nodeIndex: nodeIndex)
  let rightLineSpacing = prepared.edgeLineSpacing(for: rightEdge, nodeIndex: nodeIndex)
  let leftKey = policyCanvasCorridorComparisonKey(
    hint: routingHints?.edgeHint(for: leftID),
    lineSpacing: leftLineSpacing
  )
  let rightKey = policyCanvasCorridorComparisonKey(
    hint: routingHints?.edgeHint(for: rightID),
    lineSpacing: rightLineSpacing
  )
  guard
    !policyCanvasRoutesMayShareInteriorCorridor(
      edge: leftEdge,
      corridorKey: leftKey,
      with: rightEdge,
      otherCorridorKey: rightKey
    )
  else {
    return 0
  }
  return policyCanvasRouteMaxInteriorSharedOverlap(leftRoute, with: [rightRoute])
}
