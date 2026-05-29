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

  @Test("default graph inter-group corridor hints stay near target node bands")
  func defaultGraphInterGroupCorridorHintsStayNearTargetNodeBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let routingHints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }

    for edgeID in targetBandEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = routingHints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected target node and corridor hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY

      #expect(
        hint.horizontalLaneY >= targetBand.lowerBound,
        "\(edgeID) horizontal hint \(hint.horizontalLaneY) should stay near target-local band \(targetBand)"
      )
      #expect(
        hint.horizontalLaneY <= targetBand.upperBound,
        "\(edgeID) horizontal hint \(hint.horizontalLaneY) should stay near target-local band \(targetBand)"
      )
    }
  }

  @Test("default graph action-to-merge route uses a target-local vertical corridor")
  func defaultGraphActionToMergeRouteUsesATargetLocalVerticalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    guard
      let edge = viewModel.edges.first(where: { $0.id == "edge:merge" }),
      let targetNode = viewModel.node(edge.target.nodeID),
      let route = routes[edge.id],
      let hint = viewModel.routingHints?.edgeHint(for: edge.id),
      let dominantLaneX = policyCanvasDominantVerticalLaneCoordinate(route),
      let hintLaneX = hint.verticalLaneX
    else {
      Issue.record("Expected edge:merge route, target node, and vertical corridor hint")
      return
    }

    let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
    let preferredBand =
      (targetFrame.minX - (PolicyCanvasLayout.gridSize * 3))...targetFrame.minX

    #expect(
      preferredBand.contains(hintLaneX),
      "edge:merge hint x \(hintLaneX) should stay in target-local band \(preferredBand)"
    )
    #expect(
      preferredBand.contains(dominantLaneX),
      "edge:merge vertical lane \(dominantLaneX) should stay in target-local band \(preferredBand); route \(route.points)"
    )
  }

  @Test("default graph default route adds a target-local terminal handoff")
  func defaultGraphDefaultRouteAddsATargetLocalTerminalHandoff() {
    let (viewModel, routes) = defaultPreparedDisplayedRoutes()
    guard
      let edge = viewModel.edges.first(where: { $0.id == "edge:default" }),
      let targetNode = viewModel.node(edge.target.nodeID),
      let route = routes[edge.id],
      let terminalHandoff = finalHorizontalSegmentBeforeTarget(route)
    else {
      Issue.record("Expected edge:default route, target node, and final target-local horizontal handoff")
      return
    }

    let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
    let preferredBand =
      (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY

    #expect(
      preferredBand.contains(terminalHandoff.start.y),
      "edge:default terminal handoff y \(terminalHandoff.start.y) should stay in target-local band \(preferredBand); route \(route.points)"
    )
    #expect(
      terminalHandoff.length >= PolicyCanvasLayout.gridSize * 4,
      "edge:default should expose a substantial target-local handoff before default-allow; route \(route.points)"
    )
  }

  @Test("default graph side-port routes approach without a terminal jog")
  func defaultGraphSidePortRoutesApproachWithoutATerminalJog() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    // A route entering a leading/trailing port must arrive head-on: a single
    // straight horizontal at the port's Y. When the corridor descends to a lane
    // one grid off the port center, the tail degrades into an H-V-H stair-step
    // (corridor-exit horizontal, a short vertical jog, then the port stub). That
    // reads on screen as "the edge ends immediately after turning right". The
    // jog is only an artifact when a vertical precedes it and can absorb the
    // reconcile, so the pattern needs at least five points; a two-port Z whose
    // first leg is the source departure (no leading vertical) is legitimate.
    let maxReconcileJog = PolicyCanvasLayout.nodeSize.height
    for edge in viewModel.edges {
      guard let route = routes[edge.id], route.points.count >= 5 else { continue }
      let points = route.points
      let target = points[points.count - 1]
      let stubStart = points[points.count - 2]
      let beforeStub = points[points.count - 3]
      let beforeJog = points[points.count - 4]
      // Final approach into a side port is a horizontal stub.
      guard abs(stubStart.y - target.y) < 0.5, abs(stubStart.x - target.x) > 0.5 else {
        continue
      }
      // Penultimate segment is a vertical jog into the stub.
      guard abs(beforeStub.x - stubStart.x) < 0.5, abs(beforeStub.y - stubStart.y) > 0.5 else {
        continue
      }
      // The jog sits between two horizontals, the earlier of which is fed by a
      // vertical corridor that could have descended straight to the port.
      guard abs(beforeStub.y - beforeJog.y) < 0.5, abs(beforeStub.x - beforeJog.x) > 0.5 else {
        continue
      }
      let jog = abs(beforeStub.y - stubStart.y)
      #expect(
        jog > maxReconcileJog,
        "edge \(edge.id) jogs \(jog)pt right before its side-port approach instead of arriving straight; route \(points)"
      )
    }
  }

  @Test("default graph upper merge-to-terminal routes do not collapse onto the failure bus")
  func defaultGraphUpperMergeToTerminalRoutesDoNotCollapseOntoTheFailureBus() {
    let (_, routes) = defaultDisplayedRoutes()
    let failureRoutes = mergeDenyFailureEdgeIDs.compactMap { routes[$0] }
    #expect(failureRoutes.count == mergeDenyFailureEdgeIDs.count)
    let failureBus = dominantSharedHorizontalTrunkY(routes: failureRoutes)
    #expect(
      failureBus == nil,
      "Failure-family edges carry different labels and should not collapse to one horizontal bus; saw \(String(describing: failureBus))"
    )

    let upperFamilyLanes = upperMergeToTerminalEdgeIDs.compactMap { edgeID in
      routes[edgeID].flatMap(policyCanvasDominantHorizontalLaneCoordinate)
    }
    #expect(upperFamilyLanes.count == upperMergeToTerminalEdgeIDs.count)
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
    let trunkY = dominantSharedHorizontalTrunkY(routes: familyRoutes)
    #expect(
      trunkY == nil,
      "Failure-family edges carry different labels and should not share one trunk; saw \(String(describing: trunkY)); labels \(labelPositions)"
    )
  }

  @Test("default graph action-terminal routes resolve to per-target horizontal corridor bands")
  func defaultGraphActionTerminalRoutesResolveToPerTargetHorizontalCorridorBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let hints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }
    for edgeID in actionTerminalEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = hints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected action-terminal edge, target node, and hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
      #expect(
        targetBand.contains(hint.horizontalLaneY),
        "\(edgeID) hint y=\(hint.horizontalLaneY) should fall inside its own target band \(targetBand)"
      )
    }
  }

  @Test("default graph risk routes resolve to per-target horizontal corridor bands")
  func defaultGraphRiskRoutesResolveToPerTargetHorizontalCorridorBands() {
    let (viewModel, _) = defaultDisplayedRoutes()
    guard let hints = viewModel.routingHints else {
      Issue.record("Expected routing hints for the default policy graph")
      return
    }
    for edgeID in riskFamilyEdgeIDs {
      guard
        let edge = viewModel.edges.first(where: { $0.id == edgeID }),
        let targetNode = viewModel.node(edge.target.nodeID),
        let hint = hints.edgeHint(for: edgeID)
      else {
        Issue.record("Expected risk edge, target node, and hint for \(edgeID)")
        return
      }
      let targetFrame = CGRect(origin: targetNode.position, size: PolicyCanvasLayout.nodeSize)
      let targetBand = (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
      #expect(
        targetBand.contains(hint.horizontalLaneY),
        "\(edgeID) hint y=\(hint.horizontalLaneY) should fall inside its own target band \(targetBand)"
      )
    }
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
      // Per-target corridor design: action-terminal edges route to
      // distinct targets and need not share a horizontal trunk. Nothing
      // to assert.
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
      // Per-target corridor design: risk-family edges route to distinct
      // targets and need not share a horizontal trunk. Nothing to assert.
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

  @Test("default graph merge-to-terminal labels stay off the shared vertical corridor")
  func defaultGraphMergeToTerminalLabelsStayOffTheSharedVerticalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = mergeToTerminalLabelEdgeIDs.compactMap {
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
    #expect(placementRoutes.count == mergeToTerminalLabelEdgeIDs.count)
    guard let trunk = rightmostSharedVerticalTrunk(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: merge-to-terminal edges route to
      // distinct targets and need not share a vertical trunk. Nothing to
      // assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { $0.intersects(verticalTrunkFrame(trunk)) }

    #expect(
      labelsOnTrunk.count <= 1,
      "Expected at most one merge-to-terminal label on shared vertical corridor x=\(trunk.x), saw \(labelsOnTrunk.count) with frames \(labelsOnTrunk)"
    )
  }

  @Test("default graph middle merge-to-terminal labels stay off the shared horizontal corridor")
  func defaultGraphMiddleMergeToTerminalLabelsStayOffTheSharedHorizontalCorridor() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let placementRoutes = middleMergeToTerminalEdgeIDs.compactMap {
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
    #expect(placementRoutes.count == middleMergeToTerminalEdgeIDs.count)
    guard let trunkY = dominantSharedHorizontalTrunkY(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design (Brandes-Kopf Y assignment): middle
      // merge-to-terminal edges route to distinct horizontal bands and need
      // not share a single trunk. Nothing to assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { frame in
      abs(frame.midY - trunkY) <= PolicyCanvasLayout.gridSize
    }

    #expect(
      labelsOnTrunk.isEmpty,
      "Expected middle merge-to-terminal labels to leave the shared horizontal corridor at y=\(trunkY); saw \(labelsOnTrunk)"
    )
  }

  @Test("default graph failure-family routes fan directly without a shared vertical corridor")
  func defaultGraphFailureFamilyDuplicateLabelsStayOffTheSharedVerticalCorridor() {
    let (_, routes) = defaultDisplayedRoutes()
    let familyRoutes = mergeDenyFailureEdgeIDs.compactMap { routes[$0] }
    #expect(familyRoutes.count == mergeDenyFailureEdgeIDs.count)
    // The fail family now fans directly into merge-deny: each edge drops at its
    // own source X onto a nested rail, so there is no shared vertical corridor
    // for the duplicate "evidence failure" labels to pile onto.
    let trunk = rightmostSharedVerticalTrunk(routes: familyRoutes)
    #expect(
      trunk == nil,
      "Fail family should fan directly, not share a vertical corridor; saw \(String(describing: trunk))"
    )
  }

  @Test("default graph risk labels stay off the shared vertical departure corridor")
  func defaultGraphRiskLabelsStayOffTheSharedVerticalDepartureCorridor() {
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
    guard let trunk = rightmostSharedVerticalTrunk(routes: placementRoutes.map(\.route)) else {
      // Per-target corridor design: risk-family edges route to distinct
      // targets and need not share a vertical departure trunk. Nothing to
      // assert.
      return
    }

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let labelsOnTrunk = placementRoutes.compactMap { route in
      positions[route.id].map {
        labelFrame(center: $0, size: route.size)
      }
    }.filter { $0.intersects(verticalTrunkFrame(trunk)) }

    #expect(
      labelsOnTrunk.isEmpty,
      "Expected risk-family labels to leave the shared vertical departure corridor x=\(trunk.x); saw \(labelsOnTrunk)"
    )
  }

  @Test("default graph failure-family duplicate labels do not collapse into one column")
  func defaultGraphFailureFamilyDuplicateLabelsDoNotCollapseIntoOneColumn() {
    let (viewModel, routes) = defaultDisplayedRoutes()
    let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let label = "evidence failure"
    let placementRoutes = mergeDenyFailureEdgeIDs.compactMap { edgeID in
      routes[edgeID].map {
        PolicyCanvasLabelPlacementRoute(
          id: edgeID,
          label: label,
          route: $0,
          size: metrics.size(for: label)
        )
      }
    }
    #expect(placementRoutes.count == mergeDenyFailureEdgeIDs.count)

    let positions = policyCanvasResolvedLabelPositions(
      routes: placementRoutes,
      nodeFrames: defaultNodeAndGroupFrames(viewModel: viewModel),
      routeFrames: policyCanvasRouteFrames(placementRoutes)
    )
    let columns = Set(placementRoutes.compactMap { route in
      positions[route.id].map { Int(($0.x / PolicyCanvasLayout.gridSize).rounded()) }
    })

    #expect(
      columns.count >= 2,
      "Expected duplicate failure labels to spread across multiple columns; resolved columns \(columns) for positions \(positions)"
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

  private func defaultPreparedDisplayedRoutes() -> (
    viewModel: PolicyCanvasViewModel,
    routes: [String: PolicyCanvasEdgeRoute]
  ) {
    let document = PreviewFixtures.policyCanvasPipelineDocument()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(document: document, simulation: nil, audit: nil)
    let edges = viewModel.edges
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: edges,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let router = PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
    let nodeIndex = prepared.nodeIndex
    let initialRoutes = prepared.displayedRoutes(router: router)
    var portMarkerLayout = prepared.portMarkerLayout(
      routes: initialRoutes,
      nodeIndex: nodeIndex
    )
    var routes = initialRoutes
    var converged = false
    for _ in 0..<3 {
      routes = prepared.displayedRoutes(
        router: router,
        portMarkerLayout: portMarkerLayout
      )
      let nextPortMarkerLayout = prepared.portMarkerLayout(
        routes: routes,
        nodeIndex: nodeIndex
      )
      if nextPortMarkerLayout == portMarkerLayout {
        converged = true
        break
      }
      portMarkerLayout = nextPortMarkerLayout
    }
    if !converged {
      routes = prepared.displayedRoutes(
        router: router,
        portMarkerLayout: portMarkerLayout
      )
    }
    return (
      viewModel: viewModel,
      routes: routes
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

  private func finalHorizontalSegmentBeforeTarget(_ route: PolicyCanvasEdgeRoute) -> HorizontalSegment?
  {
    guard route.points.count >= 3 else {
      return nil
    }
    return HorizontalSegment(
      start: route.points[route.points.count - 3],
      end: route.points[route.points.count - 2]
    )
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
    if abs(laneX - preferredX) <= tolerance {
      return
    }
    // A horizontally-dominant route to a far target legitimately does not
    // capture its vertical corridor. The router only forces the corridor for
    // vertically-dominant routes (verticalSpan >= 2 * horizontalSpan in
    // policyCanvasAlignedVerticalDominantCorridorRoute); a wide, shallow route
    // drops at whatever lane keeps it clear of its fan siblings. That is still
    // a clean route as long as its dominant vertical lane stays inside its own
    // source -> target horizontal span rather than backtracking outside it.
    let sourceX = route.points.first?.x ?? laneX
    let targetX = route.points.last?.x ?? laneX
    let sourceY = route.points.first?.y ?? 0
    let targetY = route.points.last?.y ?? 0
    let horizontallyDominant = abs(targetX - sourceX) > abs(targetY - sourceY)
    let span = min(sourceX, targetX)...max(sourceX, targetX)
    #expect(
      horizontallyDominant && span.contains(laneX),
      "\(edgeID) vertical lane \(laneX) should stay near preferred corridor \(preferredX), or for a horizontal route stay inside its source-target span \(span); route \(route.points)"
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
      let leftSegments = interiorSegments(leftRoute).filter(\.isHorizontal)
      let pairMax = routes[(leftIndex + 1)...].reduce(CGFloat.zero) { pairCurrentMax, rightRoute in
        let rightSegments = interiorSegments(rightRoute).filter(\.isHorizontal)
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

  private func rightmostSharedVerticalTrunk(routes: [PolicyCanvasEdgeRoute]) -> SharedVerticalTrunk?
  {
    let sharedSegments = routes.enumerated().flatMap { leftIndex, leftRoute in
      routes[(leftIndex + 1)...].flatMap { rightRoute -> [SharedVerticalTrunk] in
        verticalSegments(leftRoute).compactMap { leftSegment in
          verticalSegments(rightRoute).compactMap { rightSegment in
            leftSegment.sharedTrunk(with: rightSegment)
          }
        }.flatMap { $0 }
      }
    }
    return sharedSegments.max { left, right in
      if abs(left.x - right.x) > 0.001 {
        return left.x < right.x
      }
      return left.overlap < right.overlap
    }
  }

  private func verticalSegments(_ route: PolicyCanvasEdgeRoute) -> [VerticalSegment] {
    zip(route.points, route.points.dropFirst()).compactMap { start, end in
      VerticalSegment(start: start, end: end)
    }
  }

  private func labelFrame(center: CGPoint, size: CGSize) -> CGRect {
    CGRect(
      x: center.x - (size.width / 2),
      y: center.y - (size.height / 2),
      width: size.width,
      height: size.height
    )
  }

  private func verticalTrunkFrame(_ trunk: SharedVerticalTrunk) -> CGRect {
    CGRect(
      x: trunk.x - PolicyCanvasLayout.gridSize,
      y: trunk.range.lowerBound,
      width: PolicyCanvasLayout.gridSize * 2,
      height: trunk.range.upperBound - trunk.range.lowerBound
    )
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

private let mergeToTerminalLabelEdgeIDs = [
  "edge:risk-high",
  "edge:risk-low",
  "edge:risk-missing",
  "edge:evidence-consensus",
  "edge:evidence-missing",
]

private let middleMergeToTerminalEdgeIDs = [
  "edge:evidence-consensus",
  "edge:evidence-missing",
  "edge:risk-missing",
]

private let targetBandEdgeIDs = [
  "edge:default",
  "edge:risk-high",
  "edge:risk-low",
  "edge:risk-missing",
  "edge:evidence-consensus",
  "edge:evidence-missing",
  "edge:evidence-fail:branch-protection-blocked",
]

private let upperMergeToTerminalEdgeIDs = [
  "edge:risk-high",
  "edge:risk-low",
  "edge:evidence-consensus",
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

private struct SharedVerticalTrunk {
  let x: CGFloat
  let range: ClosedRange<CGFloat>
  let overlap: CGFloat
}

private struct HorizontalSegment {
  let start: CGPoint
  let end: CGPoint

  var length: CGFloat {
    abs(end.x - start.x)
  }

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

private struct VerticalSegment {
  let start: CGPoint
  let end: CGPoint

  init?(start: CGPoint, end: CGPoint) {
    guard abs(start.x - end.x) < 0.001, abs(start.y - end.y) > 0.001 else {
      return nil
    }
    self.start = start
    self.end = end
  }

  func sharedTrunk(with other: Self) -> SharedVerticalTrunk? {
    guard abs(start.x - other.start.x) < 0.001 else {
      return nil
    }
    let lowerBound = max(min(start.y, end.y), min(other.start.y, other.end.y))
    let upperBound = min(max(start.y, end.y), max(other.start.y, other.end.y))
    let overlap = max(0, upperBound - lowerBound)
    guard overlap > 0.001 else {
      return nil
    }
    return SharedVerticalTrunk(
      x: start.x,
      range: lowerBound...upperBound,
      overlap: overlap
    )
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
