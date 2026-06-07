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

  @Test("extreme layout keeps groups clear of foreign nodes and titles")
  @MainActor
  func extremeLayoutSeparatesGroupsFromForeignNodes() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")
    let nodes = scene.viewModel.nodes
    let groupByNode = Dictionary(
      uniqueKeysWithValues: nodes.compactMap { node in node.groupID.map { (node.id, $0) } }
    )
    let frames = Dictionary(
      uniqueKeysWithValues: nodes.map { ($0.id, policyCanvasNodeFrame($0)) }
    )
    let ids = nodes.map(\.id)

    var nodeOverlaps: [String] = []
    for leftIndex in ids.indices {
      for rightIndex in ids.index(after: leftIndex)..<ids.endIndex {
        let leftID = ids[leftIndex]
        let rightID = ids[rightIndex]
        guard groupByNode[leftID] != groupByNode[rightID] else { continue }
        if (frames[leftID] ?? .null).intersects(frames[rightID] ?? .null) {
          nodeOverlaps.append("\(leftID)~\(rightID)")
        }
      }
    }

    let titleFrames = Array(
      zip(scene.viewModel.groups, policyCanvasGroupTitleFrames(scene.viewModel.groups))
    )
    var titleOverlaps: [String] = []
    for node in nodes {
      for (group, title) in titleFrames where group.id != node.groupID {
        if (frames[node.id] ?? .null).intersects(title) {
          titleOverlaps.append("\(node.id)@\(group.id)")
        }
      }
    }

    #expect(nodeOverlaps.isEmpty, "cross-group node overlaps: \(nodeOverlaps)")
    #expect(titleOverlaps.isEmpty, "nodes inside a foreign group title: \(titleOverlaps)")
  }

  @Test("lab sample live reformats keep node bodies at the minimum spacing")
  @MainActor
  func labSampleLiveReformatsKeepNodeBodiesAtMinimumSpacing() throws {
    var violations: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let viewModel = PolicyCanvasViewModel.sample()
      viewModel.load(document: sample.document, simulation: nil, audit: nil)
      viewModel.reflowLayout(preserveManualAnchors: false, force: true)
      violations.append(
        contentsOf: policyCanvasNodeSpacingViolations(viewModel.nodes).map { pair in
          "\(sample.id):\(pair)"
        }
      )
    }

    #expect(
      violations.isEmpty,
      "node bodies below minimum spacing after live reformat: \(violations)"
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

  private func policyCanvasNodeSpacingViolations(_ nodes: [PolicyCanvasNode]) -> [String] {
    var violations: [String] = []
    for leftIndex in nodes.indices {
      for rightIndex in nodes.index(after: leftIndex)..<nodes.endIndex {
        let left = nodes[leftIndex]
        let right = nodes[rightIndex]
        if policyCanvasNodeFramesViolateMinimumSpacing(
          policyCanvasNodeFrame(left),
          policyCanvasNodeFrame(right)
        ) {
          violations.append("\(left.id)~\(right.id)")
        }
      }
    }
    return violations
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
    let assertions = PolicyCanvasTerminalAssertions()

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

  @Test("extreme sample shared input ports render one marker per inbound edge")
  @MainActor
  func extremeSampleSharedInputPortsRenderOneMarkerPerInboundEdge() async throws {
    let scene = try await liveRoutedLabScene(sampleID: "extreme")

    try assertSharedInputPortMarkers(
      scene: scene,
      edgeIDs: ["xe:entry-route", "xe:trigger-route"],
      targetNodeID: "x-route"
    )
    try assertSharedInputPortMarkers(
      scene: scene,
      edgeIDs: ["xe:wait-merge", "xe:event-merge"],
      targetNodeID: "x-merge-step"
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

  @Test("lab sample live port markers stay balanced on every visible side")
  func labSampleLivePortMarkersStayBalanced() async throws {
    var failures: [String] = []
    for sample in PolicyCanvasLabSamples.all {
      let graph = try await markerBalanceGraph(sampleID: sample.id)
      let routeInput = PolicyCanvasRouteWorkerInput(
        nodes: graph.nodes,
        groups: graph.groups,
        edges: graph.edges,
        fontScale: 1,
        routingHints: graph.routingHints,
        algorithmSelection: .referenceRouting
      )
      let prepared = PolicyCanvasPreparedRouteInput(input: routeInput)
      let nodeIndex = prepared.nodeIndex
      var seenMarkers: Set<PolicyCanvasLabMarkerInstanceKey> = []
      var coordinatesBySide: [PolicyCanvasLabMarkerSideKey: [CGFloat]] = [:]
      for endpoint in graph.edges.flatMap({ [$0.source, $0.target] }) {
        for side in policyCanvasVisibleAndExplicitMarkerSides(
          endpoint: endpoint,
          visibility: graph.output.portVisibility,
          markerLayout: graph.output.portMarkerLayout
        ) {
          guard
            let node = nodeIndex[endpoint.nodeID],
            let basePoint = prepared.portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
          else {
            continue
          }
          for marker in graph.output.portMarkerLayout.markers(
            for: endpoint,
            side: side,
            isVisible: true
          ) {
            let instance = PolicyCanvasLabMarkerInstanceKey(
              endpoint: policyCanvasCanonicalPortEndpoint(endpoint),
              side: side,
              markerID: marker.id
            )
            guard seenMarkers.insert(instance).inserted else {
              continue
            }
            let coordinate =
              policyCanvasLocalAxisCoordinate(basePoint, side: side, frame: node.frame)
              + marker.axisOffset
            let sideKey = PolicyCanvasLabMarkerSideKey(
              sampleID: sample.id,
              nodeID: endpoint.nodeID,
              kind: endpoint.kind,
              side: side
            )
            coordinatesBySide[sideKey, default: []].append(coordinate)
          }
        }
      }
      for (sideKey, coordinates) in coordinatesBySide {
        failures.append(contentsOf: markerBalanceFailures(key: sideKey, coordinates: coordinates))
      }
      failures.append(
        contentsOf: routeTerminalMarkerFailures(
          sampleID: sample.id,
          graph: graph,
          prepared: prepared,
          nodeIndex: nodeIndex
        )
      )
    }

    #expect(
      failures.isEmpty,
      """
      live lab port markers are not balanced and aligned on every visible node side
      failures=\(failures)
      """
    )
  }

  private func markerBalanceGraph(
    sampleID: String
  ) async throws -> PolicyCanvasLabMarkerBalanceGraph {
    let laidOutGraph = try laidOutLabGraph(sampleID: sampleID)
    let routeInput = PolicyCanvasRouteWorkerInput(
      nodes: laidOutGraph.nodes,
      groups: laidOutGraph.groups,
      edges: laidOutGraph.edges,
      fontScale: 1,
      routingHints: laidOutGraph.routingHints,
      algorithmSelection: .referenceRouting
    )
    let output = await PolicyCanvasRouteWorker().compute(input: routeInput)
    return PolicyCanvasLabMarkerBalanceGraph(
      nodes: laidOutGraph.nodes,
      groups: laidOutGraph.groups,
      edges: laidOutGraph.edges,
      routingHints: laidOutGraph.routingHints,
      output: output
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

  @Test("extreme notified back-edge avoids default-side detour")
  func extremeNotifiedBackEdgeAvoidsDefaultSideDetour() async throws {
    let graph = try await routedLabGraph(sampleID: "extreme")
    let edgeID = "xe:action2-allow"
    let route = try #require(graph.output.routes[edgeID])
    let sourceSide = try #require(policyCanvasRouteSourceSide(route))
    let targetSide = try #require(policyCanvasRouteTargetSide(route))
    let sourceFrame = try #require(
      graph.nodes.first(where: { $0.id == "x-action2" }).map(policyCanvasNodeFrame)
    )
    let maxX = try #require(route.points.map(\.x).max())

    #expect(
      sourceSide != .trailing,
      "notified should not leave through the default trailing detour; route=\(route.points)"
    )
    #expect(
      targetSide != .leading,
      "notified should not enter through the default leading detour; route=\(route.points)"
    )
    #expect(
      maxX <= sourceFrame.maxX + 0.5,
      "notified should not escape to the right of x-action2; maxX=\(maxX) route=\(route.points)"
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

  private func markerBalanceFailures(
    key: PolicyCanvasLabMarkerSideKey,
    coordinates rawCoordinates: [CGFloat]
  ) -> [String] {
    let coordinates = rawCoordinates.sorted()
    let extent = policyCanvasSideExtent(side: key.side)
    if coordinates.count == 1 {
      return abs(coordinates[0] - (extent / 2)) <= 0.5
        ? []
        : ["\(key) single=\(coordinates[0]) expected=\(extent / 2)"]
    }
    guard coordinates.count > 1 else {
      return []
    }
    let deltas = zip(coordinates, coordinates.dropFirst()).map { $1 - $0 }
    let spacing = deltas[0]
    let uneven = deltas.contains { abs($0 - spacing) > 0.5 }
    let offCenter = abs((coordinates[0] + (coordinates.last ?? coordinates[0])) - extent) > 0.5
    guard uneven || offCenter else {
      return []
    }
    return [
      "\(key) coordinates=\(coordinates) deltas=\(deltas) extent=\(extent)"
    ]
  }

  private func assertSharedInputPortMarkers(
    scene: PolicyCanvasLiveLabScene,
    edgeIDs: [String],
    targetNodeID: String
  ) throws {
    let edgesByID = Dictionary(uniqueKeysWithValues: scene.edges.map { ($0.id, $0) })
    let endpoint = try #require(edgesByID[edgeIDs[0]]?.target)
    #expect(endpoint.nodeID == targetNodeID)
    let terminals = try edgeIDs.map { edgeID in
      try #require(scene.output.portMarkerLayout.terminal(edgeID: edgeID, role: .target))
    }
    #expect(terminals.allSatisfy { $0.side == .leading })
    let offsets = terminals.map(\.axisOffset).sorted()
    #expect(Set(offsets.map { Int(($0 * 1_000).rounded()) }).count == edgeIDs.count)
    let markers = scene.output.portMarkerLayout.markers(
      for: endpoint,
      side: .leading,
      isVisible: true
    )
    #expect(markers.count == edgeIDs.count)
    let coordinates = markers.map {
      PolicyCanvasLayout.nodeSize.height / 2 + $0.axisOffset
    }.sorted()
    for pair in zip(coordinates, coordinates.dropFirst()) {
      #expect(
        pair.1 - pair.0
          >= policyCanvasMinimumPortMarkerSpacing() - 0.001
      )
    }
  }

  private func policyCanvasVisibleAndExplicitMarkerSides(
    endpoint: PolicyCanvasPortEndpoint,
    visibility: PolicyCanvasPortVisibilityMap,
    markerLayout: PolicyCanvasPortMarkerLayout
  ) -> [PolicyCanvasPortSide] {
    var sides = policyCanvasVisiblePortSides(for: endpoint, visibility: visibility)
    for side in PolicyCanvasPortSide.allSides
    where markerLayout.hasMarkers(for: endpoint, side: side) {
      sides.insert(side)
    }
    return sides.sorted { $0.rawValue < $1.rawValue }
  }

  private func routeTerminalMarkerFailures(
    sampleID: String,
    graph: PolicyCanvasLabMarkerBalanceGraph,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String] {
    var failures: [String] = []
    for edge in graph.edges {
      guard let route = graph.output.routes[edge.id] else {
        failures.append("\(sampleID):\(edge.id): missing route")
        continue
      }
      failures.append(
        contentsOf: routeTerminalMarkerFailures(
          sampleID: sampleID,
          edge: edge,
          endpoint: edge.source,
          role: "source",
          point: route.points.first,
          side: policyCanvasRouteSourceSide(route),
          prepared: prepared,
          nodeIndex: nodeIndex,
          markerLayout: graph.output.portMarkerLayout
        )
      )
      failures.append(
        contentsOf: routeTerminalMarkerFailures(
          sampleID: sampleID,
          edge: edge,
          endpoint: edge.target,
          role: "target",
          point: route.points.last,
          side: policyCanvasRouteTargetSide(route),
          prepared: prepared,
          nodeIndex: nodeIndex,
          markerLayout: graph.output.portMarkerLayout
        )
      )
    }
    return failures
  }

  private func routeTerminalMarkerFailures(
    sampleID: String,
    edge: PolicyCanvasEdge,
    endpoint: PolicyCanvasPortEndpoint,
    role: String,
    point: CGPoint?,
    side: PolicyCanvasPortSide?,
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    markerLayout: PolicyCanvasPortMarkerLayout
  ) -> [String] {
    guard
      let point,
      let side,
      let base = prepared.portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    else {
      return ["\(sampleID):\(edge.id):\(role) missing terminal side or base"]
    }
    let offset = terminalAxisOffset(from: base, to: point, side: side)
    let markerOffsets = markerLayout.markers(for: endpoint, side: side, isVisible: true)
      .map(\.axisOffset)
    guard markerOffsets.contains(where: { abs($0 - offset) <= 0.5 }) else {
      return [
        "\(sampleID):\(edge.id):\(role) side=\(side) offset=\(offset) markers=\(markerOffsets)"
      ]
    }
    return []
  }

  private func terminalAxisOffset(
    from base: CGPoint,
    to point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y - base.y
    case .top, .bottom:
      point.x - base.x
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

private struct PolicyCanvasLabMarkerBalanceGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let output: PolicyCanvasRouteWorkerOutput
}

private struct PolicyCanvasLabMarkerSideKey: Hashable, CustomStringConvertible {
  let sampleID: String
  let nodeID: String
  let kind: PolicyCanvasPortKind
  let side: PolicyCanvasPortSide

  var description: String {
    "\(sampleID):\(nodeID):\(kind):\(side)"
  }
}

private struct PolicyCanvasLabMarkerInstanceKey: Hashable {
  let endpoint: PolicyCanvasPortEndpoint
  let side: PolicyCanvasPortSide
  let markerID: String
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
