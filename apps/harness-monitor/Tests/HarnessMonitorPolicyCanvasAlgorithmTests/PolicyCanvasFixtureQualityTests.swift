import CoreGraphics
import ElkSwift
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas canonical fixture quality", .serialized)
struct PolicyCanvasFixtureQualityTests {
  @Test("default fixture keeps visible bounds reasonably tight")
  func defaultFixtureKeepsVisibleBoundsReasonablyTight() throws {
    let metrics = try routedFixtureMetrics(.defaultGraph)
    if metrics.elapsedMS > 33 {
      print("defaultGraph timings: \(metrics.timingSummary)")
      Issue.record("defaultGraph timings: \(metrics.timingSummary)")
    }

    #expect(
      metrics.bboxInflationRatio <= 0.35,
      """
      default fixture visible bounds are too inflated.
      bboxInflationRatio=\(metrics.bboxInflationRatio)
      visibleBounds=\(metrics.visibleBounds)
      graphHull=\(metrics.graphHull)
      routeHull=\(metrics.routeHull)
      timings=\(metrics.timingSummary)
      """
    )
    #expect(
      metrics.elapsedMS <= 33,
      """
      default fixture routing exceeded the interaction budget.
      elapsedMS=\(metrics.elapsedMS)
      timings=\(metrics.timingSummary)
      """
    )
  }

  @Test("multi-group fixture avoids incompatible interior bundle sharing")
  func multiGroupFixtureAvoidsIncompatibleInteriorBundleSharing() throws {
    let metrics = try routedFixtureMetrics(.multiGroup)
    if metrics.elapsedMS > 33 {
      print("multiGroup timings: \(metrics.timingSummary)")
      Issue.record("multiGroup timings: \(metrics.timingSummary)")
    }

    #expect(
      metrics.incompatibleSharedPairs.isEmpty,
      """
      multi-group fixture still shares interior corridor space across incompatible edge families.
      incompatibleSharedPairs=\(metrics.incompatibleSharedPairs)
      timings=\(metrics.timingSummary)
      """
    )
    #expect(
      metrics.elapsedMS <= 33,
      """
      multi-group fixture routing exceeded the medium interaction budget.
      elapsedMS=\(metrics.elapsedMS)
      timings=\(metrics.timingSummary)
      """
    )
  }

  @Test("extreme fixture stays inside the local graph band")
  func extremeFixtureStaysInsideTheLocalGraphBand() throws {
    let metrics = try routedFixtureMetrics(.extreme)
    if metrics.elapsedMS > 100 {
      print("extreme timings: \(metrics.timingSummary)")
      Issue.record("extreme timings: \(metrics.timingSummary)")
    }

    #expect(
      metrics.perimeterEscape <= PolicyCanvasLayout.nodeSize.height,
      """
      extreme fixture routes still escape the local graph band.
      perimeterEscape=\(metrics.perimeterEscape)
      graphHull=\(metrics.graphHull)
      routeHull=\(metrics.routeHull)
      timings=\(metrics.timingSummary)
      """
    )
    #expect(
      metrics.elapsedMS <= 100,
      """
      extreme fixture routing exceeded the large interaction budget.
      elapsedMS=\(metrics.elapsedMS)
      timings=\(metrics.timingSummary)
      """
    )
  }

  @Test("canonical fixture routing is deterministic across reversed edge order")
  func canonicalFixtureRoutingIsDeterministicAcrossEdgeOrder() throws {
    let forward = try evaluateFixture(.multiGroup, reversesEdges: false)
    let reversed = try evaluateFixture(.multiGroup, reversesEdges: true)
    let edgeIDs = Array(Set(forward.routes.keys).intersection(reversed.routes.keys)).sorted()
    if forward.orderedEdgeIDs != reversed.orderedEdgeIDs {
      let debugIDs = Array(Set(forward.buildOrderDebug.keys).union(reversed.buildOrderDebug.keys)).sorted()
      let debug = debugIDs.map { edgeID in
        """
        \(edgeID)
          forward: \(forward.buildOrderDebug[edgeID, default: "<missing>"])
          reversed: \(reversed.buildOrderDebug[edgeID, default: "<missing>"])
        """
      }.joined(separator: "\n")
      Issue.record("multiGroup build-order debug:\n\(debug)")
    }

    #expect(
      forward.orderedEdgeIDs == reversed.orderedEdgeIDs,
      """
      route build order changed when the multi-group fixture edge order reversed.
      forward=\(forward.orderedEdgeIDs)
      reversed=\(reversed.orderedEdgeIDs)
      """
    )

    for edgeID in edgeIDs {
      let forwardRoute = try #require(forward.routes[edgeID])
      let reversedRoute = try #require(reversed.routes[edgeID])
      #expect(
        forwardRoute.points == reversedRoute.points,
        """
        route for \(edgeID) changed when the multi-group fixture edge order reversed.
        forward=\(forwardRoute.points)
        reversed=\(reversedRoute.points)
        """
      )
    }
  }

  @Test("fixture quality scorecard exposes structural dimensions")
  func fixtureQualityScorecardExposesStructuralDimensions() throws {
    let scorecard = try routedFixtureScorecard(.multiGroup)
    #expect(scorecard.totalBends > 0)
    #expect(scorecard.labelOverlapPairs.isEmpty)
    #expect(scorecard.determinismMismatchCount == 0)
    #expect(scorecard.elapsedMS >= 0)
  }

  @Test("benchmark comparison pairs harness current with an internal reference baseline")
  func benchmarkComparisonPairsHarnessCurrentWithInternalReferenceBaseline() throws {
    let comparison = try routedFixtureBenchmarkComparison(
      .multiGroup,
      candidate: .harnessCurrent,
      baseline: .referencePure
    )
    #expect(comparison.candidate.name == "Harness current")
    #expect(comparison.baseline.name == "Reference pure")
    #expect(comparison.candidate.routeCount == PolicyCanvasCanonicalFixture.multiGroup.edges.count)
    #expect(comparison.baseline.routeCount == PolicyCanvasCanonicalFixture.multiGroup.edges.count)
  }

  @Test("benchmark comparison can use the ELK layered external baseline")
  func benchmarkComparisonCanUseTheELKLayeredExternalBaseline() throws {
    let comparison = try routedFixtureBenchmarkComparison(
      .multiGroup,
      candidate: .harnessCurrent,
      baseline: .elkLayered
    )
    #expect(comparison.baseline.name == "ELK layered")
    #expect(comparison.baseline.routeCount == PolicyCanvasCanonicalFixture.multiGroup.edges.count)
    #expect(comparison.baseline.scorecard.totalBends > 0)
  }

  private func routedFixtureMetrics(
    _ fixture: PolicyCanvasCanonicalFixture
  ) throws -> PolicyCanvasCanonicalFixtureMetrics {
    try PolicyCanvasCanonicalFixtureMetrics(evaluation: evaluateFixture(fixture))
  }

  private func routedFixtureScorecard(
    _ fixture: PolicyCanvasCanonicalFixture
  ) throws -> PolicyCanvasCanonicalFixtureScorecard {
    let forward = try evaluateFixture(fixture)
    let reversed = try evaluateFixture(fixture, reversesEdges: true)
    return PolicyCanvasCanonicalFixtureScorecard(forward: forward, reversed: reversed)
  }

  private func routedFixtureBenchmarkComparison(
    _ fixture: PolicyCanvasCanonicalFixture,
    candidate: PolicyCanvasCanonicalFixtureInternalBaseline,
    baseline: PolicyCanvasCanonicalFixtureInternalBaseline
  ) throws -> PolicyCanvasCanonicalFixtureBenchmarkComparison {
    try routedFixtureBenchmarkComparison(
      fixture,
      candidate: candidate as any PolicyCanvasCanonicalFixtureBaseline,
      baseline: baseline as any PolicyCanvasCanonicalFixtureBaseline
    )
  }

  private func routedFixtureBenchmarkComparison(
    _ fixture: PolicyCanvasCanonicalFixture,
    candidate: any PolicyCanvasCanonicalFixtureBaseline,
    baseline: any PolicyCanvasCanonicalFixtureBaseline
  ) throws -> PolicyCanvasCanonicalFixtureBenchmarkComparison {
    try PolicyCanvasCanonicalFixtureBenchmarkComparison(
      fixtureID: fixture.id,
      candidate: .init(
        name: candidate.name,
        forward: candidate.run(fixture: fixture, reversesEdges: false),
        reversed: candidate.run(fixture: fixture, reversesEdges: true)
      ),
      baseline: .init(
        name: baseline.name,
        forward: baseline.run(fixture: fixture, reversesEdges: false),
        reversed: baseline.run(fixture: fixture, reversesEdges: true)
      )
    )
  }

  private func evaluateFixture(
    _ fixture: PolicyCanvasCanonicalFixture,
    reversesEdges: Bool = false,
    algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
  ) throws -> PolicyCanvasCanonicalFixtureEvaluation {
    try policyCanvasEvaluateFixture(
      fixture,
      reversesEdges: reversesEdges,
      algorithmSelection: algorithmSelection
    )
  }
}

private func policyCanvasEvaluateFixture(
  _ fixture: PolicyCanvasCanonicalFixture,
  reversesEdges: Bool = false,
  algorithmSelection: PolicyCanvasAlgorithmSelection = .harnessCurrent
) throws -> PolicyCanvasCanonicalFixtureEvaluation {
    var nodes = fixture.nodes
    var groups = fixture.groups
    let layoutStartedAt = CFAbsoluteTimeGetCurrent()
    let layoutResult = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: nodes,
        groups: groups,
        edges: fixture.edges,
        mode: .explicitReflow(preserveManualAnchors: false),
        algorithmSelection: algorithmSelection
      )
    )
    let routingHints = applyPolicyCanvasLayoutResult(
      layoutResult,
      nodes: &nodes,
      groups: &groups,
      centerInMinimumCanvas: true
    )
    let layoutMS = (CFAbsoluteTimeGetCurrent() - layoutStartedAt) * 1000
    var edges = fixture.edges
    if reversesEdges {
      edges.reverse()
    }

    let input = PolicyCanvasRouteWorkerInput(
      nodes: nodes,
      groups: groups,
      edges: edges,
      fontScale: 1,
      routingHints: routingHints,
      algorithmSelection: algorithmSelection
    )
    let prepared = PolicyCanvasPreparedRouteInput(input: input)
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: input.algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      input.algorithmSelection.algorithmID(for: .edgeRouting)
      == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
      : algorithms.edgeRouter
    let memoizedRouter = selectedRouter as? PolicyCanvasMemoizedRouter
    let nodeIndex = prepared.nodeIndex
    let portAnchors = prepared.portAnchors(nodeIndex: nodeIndex)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let orderedEdgeIDs = orderedEdges.map(\.id)
    let buildOrderDebug = Dictionary(
      uniqueKeysWithValues: edges.map { edge in
        let sortValues = policyCanvasRouteBuildSortValues(edge: edge, portAnchors: portAnchors)
        return (
          edge.id,
          "span=\(sortValues.span) source=\(sortValues.source) target=\(sortValues.target)"
        )
      }
    )
    let routingStartedAt = CFAbsoluteTimeGetCurrent()
    var routingPassSummaries: [String] = []
    memoizedRouter?.resetStatistics()
    let initialRoutesStartedAt = CFAbsoluteTimeGetCurrent()
    var routes = prepared.displayedRoutes(router: selectedRouter)
    let initialRoutesMS = (CFAbsoluteTimeGetCurrent() - initialRoutesStartedAt) * 1000
    let initialRouteHits = memoizedRouter?.hits ?? 0
    let initialRouteMisses = memoizedRouter?.misses ?? 0
    let initialMarkersStartedAt = CFAbsoluteTimeGetCurrent()
    var portMarkerLayout = prepared.portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let initialMarkersMS = (CFAbsoluteTimeGetCurrent() - initialMarkersStartedAt) * 1000
    routingPassSummaries.append(
      "pass0RoutesMS=\(initialRoutesMS) pass0MarkersMS=\(initialMarkersMS) hits=\(initialRouteHits) misses=\(initialRouteMisses)"
    )
    var seenLayouts: [PolicyCanvasPortMarkerLayout] = [portMarkerLayout]

    for passIndex in 1...3 {
      memoizedRouter?.resetStatistics()
      let passRoutesStartedAt = CFAbsoluteTimeGetCurrent()
      let nextRoutes = prepared.displayedRoutes(
        router: selectedRouter,
        portMarkerLayout: portMarkerLayout
      )
      let passRoutesMS = (CFAbsoluteTimeGetCurrent() - passRoutesStartedAt) * 1000
      let passRouteHits = memoizedRouter?.hits ?? 0
      let passRouteMisses = memoizedRouter?.misses ?? 0
      let passMarkersStartedAt = CFAbsoluteTimeGetCurrent()
      let nextLayout = prepared.portMarkerLayout(
        routes: nextRoutes,
        nodeIndex: nodeIndex
      )
      let passMarkersMS = (CFAbsoluteTimeGetCurrent() - passMarkersStartedAt) * 1000
      let changedRouteCount = policyCanvasChangedRouteCount(previous: routes, next: nextRoutes)
      let changedTerminalCount = policyCanvasChangedTerminalCount(
        edges: edges,
        previous: portMarkerLayout,
        next: nextLayout
      )
      routingPassSummaries.append(
        """
        pass\(passIndex)RoutesMS=\(passRoutesMS) \
        pass\(passIndex)MarkersMS=\(passMarkersMS) \
        hits=\(passRouteHits) misses=\(passRouteMisses) \
        changedRoutes=\(changedRouteCount) changedTerminals=\(changedTerminalCount)
        """
      )
      if nextLayout == portMarkerLayout {
        routes = nextRoutes
        portMarkerLayout = nextLayout
        break
      }
      if seenLayouts.contains(nextLayout) {
        routes = prepared.displayedRoutes(
          router: selectedRouter,
          portMarkerLayout: nextLayout
        )
        portMarkerLayout = nextLayout
        break
      }
      seenLayouts.append(nextLayout)
      routes = nextRoutes
      portMarkerLayout = nextLayout
    }
    let routingMS = (CFAbsoluteTimeGetCurrent() - routingStartedAt) * 1000
    let postProcessingStartedAt = CFAbsoluteTimeGetCurrent()
    let postProcessedRoutes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: prepared, routes: routes)
    )
    let postProcessingMS = (CFAbsoluteTimeGetCurrent() - postProcessingStartedAt) * 1000

    let labelStartedAt = CFAbsoluteTimeGetCurrent()
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(
        prepared: prepared,
        routes: postProcessedRoutes
      )
    )
    let labelMS = (CFAbsoluteTimeGetCurrent() - labelStartedAt) * 1000
    let elapsedMS = routingMS + postProcessingMS + labelMS

    return PolicyCanvasCanonicalFixtureEvaluation(
      nodes: nodes,
      groups: groups,
      edges: edges,
      routingHints: routingHints,
      orderedEdgeIDs: orderedEdgeIDs,
      buildOrderDebug: buildOrderDebug,
      routes: postProcessedRoutes,
      labelPositions: labelPositions,
      visibleBounds: prepared.visibleBounds(
        routes: postProcessedRoutes,
        labelPositions: labelPositions
      ),
      elapsedMS: elapsedMS,
      timingSummary:
        "layoutMS=\(layoutMS) routingMS=\(routingMS) postProcessingMS=\(postProcessingMS) labelMS=\(labelMS) \(routingPassSummaries.joined(separator: " "))"
    )
  }

private struct PolicyCanvasCanonicalFixtureMetrics {
  let graphHull: CGRect
  let routeHull: CGRect
  let visibleBounds: CGRect
  let perimeterEscape: CGFloat
  let bboxInflationRatio: CGFloat
  let incompatibleSharedPairs: [(leftID: String, rightID: String, sharedOverlap: CGFloat)]
  let elapsedMS: Double
  let timingSummary: String

  init(evaluation: PolicyCanvasCanonicalFixtureEvaluation) throws {
    graphHull = policyCanvasGraphHull(nodes: evaluation.nodes, groups: evaluation.groups)
    routeHull = policyCanvasRouteHull(routes: evaluation.routes)
    visibleBounds = evaluation.visibleBounds
    perimeterEscape =
      max(0, graphHull.minX - routeHull.minX)
      + max(0, graphHull.minY - routeHull.minY)
      + max(0, routeHull.maxX - graphHull.maxX)
      + max(0, routeHull.maxY - graphHull.maxY)
    let graphArea = max(1, graphHull.width * graphHull.height)
    let visibleArea = max(1, visibleBounds.width * visibleBounds.height)
    bboxInflationRatio = max(0, visibleArea - graphArea) / graphArea
    incompatibleSharedPairs = try policyCanvasIncompatibleSharedPairs(evaluation)
    elapsedMS = evaluation.elapsedMS
    timingSummary = evaluation.timingSummary
  }
}

private struct PolicyCanvasCanonicalFixtureEvaluation {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let orderedEdgeIDs: [String]
  let buildOrderDebug: [String: String]
  let routes: [String: PolicyCanvasEdgeRoute]
  let labelPositions: [String: CGPoint]
  let visibleBounds: CGRect
  let elapsedMS: Double
  let timingSummary: String
}

private struct PolicyCanvasCanonicalFixtureScorecard {
  let totalBends: Int
  let labelOverlapPairs: [(leftID: String, rightID: String)]
  let determinismMismatchCount: Int
  let elapsedMS: Double

  init(
    forward: PolicyCanvasCanonicalFixtureEvaluation,
    reversed: PolicyCanvasCanonicalFixtureEvaluation
  ) {
    totalBends = forward.routes.values.reduce(into: 0) { total, route in
      total += policyCanvasRouteMetrics(route).bends
    }
    labelOverlapPairs = policyCanvasLabelOverlapPairs(forward)
    determinismMismatchCount = policyCanvasDeterminismMismatchCount(
      forward: forward,
      reversed: reversed
    )
    elapsedMS = forward.elapsedMS
  }
}

private struct PolicyCanvasCanonicalFixtureBenchmarkComparison {
  let fixtureID: String
  let candidate: PolicyCanvasCanonicalFixtureBenchmarkResult
  let baseline: PolicyCanvasCanonicalFixtureBenchmarkResult
}

private struct PolicyCanvasCanonicalFixtureBenchmarkResult {
  let name: String
  let routeCount: Int
  let scorecard: PolicyCanvasCanonicalFixtureScorecard

  init(
    name: String,
    forward: PolicyCanvasCanonicalFixtureEvaluation,
    reversed: PolicyCanvasCanonicalFixtureEvaluation
  ) throws {
    self.name = name
    routeCount = forward.routes.count
    scorecard = PolicyCanvasCanonicalFixtureScorecard(forward: forward, reversed: reversed)
  }
}

private protocol PolicyCanvasCanonicalFixtureBaseline {
  var name: String { get }
  func run(
    fixture: PolicyCanvasCanonicalFixture,
    reversesEdges: Bool
  ) throws -> PolicyCanvasCanonicalFixtureEvaluation
}

private enum PolicyCanvasCanonicalFixtureInternalBaseline: PolicyCanvasCanonicalFixtureBaseline {
  case harnessCurrent
  case referencePure
  case elkLayered

  var name: String {
    switch self {
    case .harnessCurrent:
      "Harness current"
    case .referencePure:
      "Reference pure"
    case .elkLayered:
      "ELK layered"
    }
  }

  private var algorithmSelection: PolicyCanvasAlgorithmSelection {
    switch self {
    case .harnessCurrent:
      .harnessCurrent
    case .referencePure:
      .referencePure
    case .elkLayered:
      .harnessCurrent
    }
  }

  func run(
    fixture: PolicyCanvasCanonicalFixture,
    reversesEdges: Bool = false
  ) throws -> PolicyCanvasCanonicalFixtureEvaluation {
    switch self {
    case .harnessCurrent, .referencePure:
      try policyCanvasEvaluateFixture(
        fixture,
        reversesEdges: reversesEdges,
        algorithmSelection: algorithmSelection
      )
    case .elkLayered:
      try policyCanvasEvaluateELKFixture(fixture, reversesEdges: reversesEdges)
    }
  }
}

private func policyCanvasEvaluateELKFixture(
  _ fixture: PolicyCanvasCanonicalFixture,
  reversesEdges: Bool = false
) throws -> PolicyCanvasCanonicalFixtureEvaluation {
    var edges = fixture.edges
    if reversesEdges {
      edges.reverse()
    }

    let elkStartedAt = CFAbsoluteTimeGetCurrent()
    let graph = try ELK().layout(
      graph: policyCanvasELKGraph(nodes: fixture.nodes, edges: edges),
      timeout: 5
    )
    let elkMS = (CFAbsoluteTimeGetCurrent() - elkStartedAt) * 1000
    let layout = try policyCanvasDecodeELKGraph(graph)

    let nodePositions = Dictionary(
      uniqueKeysWithValues: layout.children.map { child in
        (child.id, CGPoint(x: child.x, y: child.y))
      }
    )
    let nodes = fixture.nodes.map { node in
      var next = node
      if let position = nodePositions[node.id] {
        next.position = position
      }
      return next
    }
    let groups = fixture.groups.map { group in
      var next = group
      let members = nodes.filter { $0.groupID == group.id }
      if let frame = policyCanvasGroupFrame(containing: members) {
        next.frame = frame
      }
      return next
    }

    let routes = try policyCanvasELKRoutes(layout: layout, nodes: nodes, edges: edges)
    let prepared = PolicyCanvasPreparedRouteInput(input: .init(
      nodes: nodes,
      groups: groups,
      edges: edges,
      fontScale: 1,
      routingHints: nil,
      algorithmSelection: .harnessCurrent
    ))
    let labelStartedAt = CFAbsoluteTimeGetCurrent()
    let labelPositions = PolicyCanvasAlgorithmRegistry
      .routingAlgorithms(for: .harnessCurrent)
      .labelPlacement
      .placeLabels(input: .init(prepared: prepared, routes: routes))
    let labelMS = (CFAbsoluteTimeGetCurrent() - labelStartedAt) * 1000

    return PolicyCanvasCanonicalFixtureEvaluation(
      nodes: nodes,
      groups: groups,
      edges: edges,
      routingHints: nil,
      orderedEdgeIDs: routes.keys.sorted(),
      buildOrderDebug: [:],
      routes: routes,
      labelPositions: labelPositions,
      visibleBounds: prepared.visibleBounds(routes: routes, labelPositions: labelPositions),
      elapsedMS: elkMS + labelMS,
      timingSummary: "elkMS=\(elkMS) labelMS=\(labelMS)"
    )
}

private func policyCanvasELKGraph(
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) -> [String: Any] {
  [
    "id": "root",
    "layoutOptions": [
      "elk.algorithm": "layered",
      "elk.direction": "RIGHT",
      "elk.edgeRouting": "ORTHOGONAL",
      "elk.spacing.nodeNode": 80,
      "elk.layered.spacing.nodeNodeBetweenLayers": 120
    ],
    "children": nodes.map(policyCanvasELKNode),
    "edges": edges.map(policyCanvasELKEdge)
  ]
}

private func policyCanvasELKNode(_ node: PolicyCanvasNode) -> [String: Any] {
  [
    "id": node.id,
    "width": Double(PolicyCanvasLayout.nodeSize.width),
    "height": Double(PolicyCanvasLayout.nodeSize.height),
    "ports": (node.inputPorts.map { port in
      policyCanvasELKPort(nodeID: node.id, port: port, side: "WEST")
    } + node.outputPorts.map { port in
      policyCanvasELKPort(nodeID: node.id, port: port, side: "EAST")
    }),
    "layoutOptions": [
      "elk.portConstraints": "FIXED_ORDER"
    ]
  ]
}

private func policyCanvasELKPort(
  nodeID: String,
  port: PolicyCanvasPort,
  side: String
) -> [String: Any] {
  [
    "id": policyCanvasELKPortID(nodeID: nodeID, portID: port.id),
    "width": 8,
    "height": 8,
    "layoutOptions": [
      "elk.port.side": side
    ]
  ]
}

private func policyCanvasELKEdge(_ edge: PolicyCanvasEdge) -> [String: Any] {
  [
    "id": edge.id,
    "sources": [policyCanvasELKPortID(nodeID: edge.source.nodeID, portID: edge.source.portID)],
    "targets": [policyCanvasELKPortID(nodeID: edge.target.nodeID, portID: edge.target.portID)]
  ]
}

private func policyCanvasELKPortID(nodeID: String, portID: String) -> String {
  "\(nodeID)::\(portID)"
}

private func policyCanvasDecodeELKGraph(
  _ graph: [String: Any]
) throws -> PolicyCanvasELKGraph {
  let data = try JSONSerialization.data(withJSONObject: graph)
  return try JSONDecoder().decode(PolicyCanvasELKGraph.self, from: data)
}

private func policyCanvasELKRoutes(
  layout: PolicyCanvasELKGraph,
  nodes: [PolicyCanvasNode],
  edges: [PolicyCanvasEdge]
) throws -> [String: PolicyCanvasEdgeRoute] {
  let nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
  let layoutEdgesByID = Dictionary(uniqueKeysWithValues: layout.edges.map { ($0.id, $0) })
  return try Dictionary(
    uniqueKeysWithValues: edges.enumerated().map { lane, edge in
      let points: [CGPoint] =
        if let layoutEdge = layoutEdgesByID[edge.id] {
          policyCanvasELKRoutePoints(layoutEdge)
        } else {
          []
        }
      let routePoints: [CGPoint] =
        if points.count >= 2 {
          points
        } else {
          try policyCanvasELKFallbackRoutePoints(
            edge: edge,
            nodesByID: nodesByID,
            lane: lane
          )
        }
      let midpointFallback = routePoints[routePoints.count / 2]
      let midpointRoute = PolicyCanvasEdgeRoute(
        points: routePoints,
        labelPosition: midpointFallback
      )
      return (
        edge.id,
        PolicyCanvasEdgeRoute(
          points: routePoints,
          labelPosition: midpointRoute.arcLengthMidpoint
        )
      )
    }
  )
}

private func policyCanvasELKRoutePoints(_ edge: PolicyCanvasELKGraph.Edge) -> [CGPoint] {
  edge.sections.reduce(into: [CGPoint]()) { points, section in
    policyCanvasAppendELKPoint(section.startPoint.cgPoint, to: &points)
    for bendPoint in section.bendPoints {
      policyCanvasAppendELKPoint(bendPoint.cgPoint, to: &points)
    }
    policyCanvasAppendELKPoint(section.endPoint.cgPoint, to: &points)
  }
}

private func policyCanvasAppendELKPoint(_ point: CGPoint, to points: inout [CGPoint]) {
  guard points.last != point else {
    return
  }
  points.append(point)
}

private func policyCanvasELKFallbackRoutePoints(
  edge: PolicyCanvasEdge,
  nodesByID: [String: PolicyCanvasNode],
  lane: Int
) throws -> [CGPoint] {
  guard
    let sourceNode = nodesByID[edge.source.nodeID],
    let targetNode = nodesByID[edge.target.nodeID]
  else {
    throw PolicyCanvasELKFixtureError.missingNode(edgeID: edge.id)
  }
  let source = policyCanvasELKAnchor(endpoint: edge.source, node: sourceNode)
  let target = policyCanvasELKAnchor(endpoint: edge.target, node: targetNode)
  let fallbackRoute = PolicyCanvasEdgeRoute(
    source: source,
    target: target,
    lane: lane
  )
  return fallbackRoute.points
}

private func policyCanvasELKAnchor(
  endpoint: PolicyCanvasPortEndpoint,
  node: PolicyCanvasNode
) -> CGPoint {
  let frame = CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
  switch endpoint.side ?? policyCanvasELKDefaultSide(for: endpoint.kind) {
  case .leading:
    return CGPoint(x: frame.minX, y: frame.midY)
  case .trailing:
    return CGPoint(x: frame.maxX, y: frame.midY)
  case .top:
    return CGPoint(x: frame.midX, y: frame.minY)
  case .bottom:
    return CGPoint(x: frame.midX, y: frame.maxY)
  }
}

private func policyCanvasELKDefaultSide(
  for kind: PolicyCanvasPortKind
) -> PolicyCanvasPortSide {
  switch kind {
  case .input:
    .leading
  case .output:
    .trailing
  }
}

private enum PolicyCanvasELKFixtureError: Error {
  case missingNode(edgeID: String)
}

private struct PolicyCanvasELKGraph: Decodable {
  let children: [Child]
  let edges: [Edge]

  private enum CodingKeys: String, CodingKey {
    case children
    case edges
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    children = try container.decodeIfPresent([Child].self, forKey: .children) ?? []
    edges = try container.decodeIfPresent([Edge].self, forKey: .edges) ?? []
  }

  struct Child: Decodable {
    let id: String
    let x: CGFloat
    let y: CGFloat
  }

  struct Edge: Decodable {
    let id: String
    let sections: [Section]

    private enum CodingKeys: String, CodingKey {
      case id
      case sections
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      id = try container.decode(String.self, forKey: .id)
      sections = try container.decodeIfPresent([Section].self, forKey: .sections) ?? []
    }
  }

  struct Section: Decodable {
    let startPoint: Point
    let endPoint: Point
    let bendPoints: [Point]

    private enum CodingKeys: String, CodingKey {
      case startPoint
      case endPoint
      case bendPoints
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      startPoint = try container.decode(Point.self, forKey: .startPoint)
      endPoint = try container.decode(Point.self, forKey: .endPoint)
      bendPoints = try container.decodeIfPresent([Point].self, forKey: .bendPoints) ?? []
    }
  }

  struct Point: Decodable {
    let x: CGFloat
    let y: CGFloat

    var cgPoint: CGPoint {
      CGPoint(x: x, y: y)
    }
  }
}

private struct PolicyCanvasCanonicalFixture {
  let id: String
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
}

private func policyCanvasChangedRouteCount(
  previous: [String: PolicyCanvasEdgeRoute],
  next: [String: PolicyCanvasEdgeRoute]
) -> Int {
  Set(previous.keys).union(next.keys).reduce(into: 0) { total, edgeID in
    if previous[edgeID]?.points != next[edgeID]?.points {
      total += 1
    }
  }
}

private func policyCanvasChangedTerminalCount(
  edges: [PolicyCanvasEdge],
  previous: PolicyCanvasPortMarkerLayout,
  next: PolicyCanvasPortMarkerLayout
) -> Int {
  edges.reduce(into: 0) { total, edge in
    if previous.terminal(edgeID: edge.id, role: .source) != next.terminal(edgeID: edge.id, role: .source) {
      total += 1
    }
    if previous.terminal(edgeID: edge.id, role: .target) != next.terminal(edgeID: edge.id, role: .target) {
      total += 1
    }
  }
}

private func policyCanvasLabelOverlapPairs(
  _ evaluation: PolicyCanvasCanonicalFixtureEvaluation
) -> [(leftID: String, rightID: String)] {
  let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
  let edgesByID = Dictionary(uniqueKeysWithValues: evaluation.edges.map { ($0.id, $0) })
  let labelFrames = evaluation.labelPositions.keys.sorted().compactMap {
    edgeID -> (id: String, frame: CGRect)? in
    guard
      let edge = edgesByID[edgeID],
      !edge.label.isEmpty,
      let center = evaluation.labelPositions[edgeID]
    else {
      return nil
    }
    return (edgeID, labelMetrics.frame(for: edge.label, center: center))
  }

  var overlaps: [(leftID: String, rightID: String)] = []
  for leftIndex in labelFrames.indices {
    for rightIndex in labelFrames.indices where rightIndex > leftIndex {
      let overlap = labelFrames[leftIndex].frame.intersection(labelFrames[rightIndex].frame)
      if !overlap.isNull, overlap.width > 0.5, overlap.height > 0.5 {
        overlaps.append(
          (leftID: labelFrames[leftIndex].id, rightID: labelFrames[rightIndex].id)
        )
      }
    }
  }
  return overlaps
}

private func policyCanvasDeterminismMismatchCount(
  forward: PolicyCanvasCanonicalFixtureEvaluation,
  reversed: PolicyCanvasCanonicalFixtureEvaluation
) -> Int {
  let forwardOrder = Dictionary(
    uniqueKeysWithValues: zip(forward.orderedEdgeIDs, forward.orderedEdgeIDs.indices)
  )
  let reversedOrder = Dictionary(
    uniqueKeysWithValues: zip(reversed.orderedEdgeIDs, reversed.orderedEdgeIDs.indices)
  )
  return Set(forward.routes.keys)
    .union(reversed.routes.keys)
    .reduce(into: 0) { total, edgeID in
      let orderMismatch = forwardOrder[edgeID] != reversedOrder[edgeID]
      let routeMismatch = forward.routes[edgeID]?.points != reversed.routes[edgeID]?.points
      if orderMismatch || routeMismatch {
        total += 1
      }
    }
}

private extension PolicyCanvasCanonicalFixture {
  static let defaultGraph: Self = {
    let nodes = [
      fixtureNode(
        "action:router",
        "Action gate",
        kind: .actionGate,
        position: CGPoint(x: 120, y: 240),
        groupID: "entry",
        inputs: ["in"],
        outputs: ["default", "mutate", "merge", "unsafe"]
      ),
      fixtureNode(
        "switch:merge:checks-green",
        "Checks green?",
        kind: .switch,
        position: CGPoint(x: 520, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["case_1", "case_2", "default"]
      ),
      fixtureNode(
        "switch:merge:branch-protection",
        "Branch protection?",
        kind: .switch,
        position: CGPoint(x: 760, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["case_1", "case_2", "default"]
      ),
      fixtureNode(
        "switch:merge:reviewer-approved",
        "Reviewer approved?",
        kind: .switch,
        position: CGPoint(x: 1000, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["case_1", "case_2", "default"]
      ),
      fixtureNode(
        "switch:merge:requested-changes",
        "No requested changes?",
        kind: .switch,
        position: CGPoint(x: 1240, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["case_1", "case_2", "default"]
      ),
      fixtureNode(
        "switch:merge:protected-path",
        "Protected path clear?",
        kind: .switch,
        position: CGPoint(x: 1480, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["case_1", "case_2", "default"]
      ),
      fixtureNode(
        "risk:merge",
        "Merge risk",
        kind: .riskClassifier,
        position: CGPoint(x: 1720, y: 120),
        groupID: "merge",
        inputs: ["in"],
        outputs: ["low_or_equal", "high", "missing"]
      ),
      fixtureNode(
        "supervisor:default-allow",
        "Default allow",
        kind: .supervisorRule,
        position: CGPoint(x: 120, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "dry_run:mutate_repo",
        "Dry-run mutate repo",
        kind: .dryRunGate,
        position: CGPoint(x: 380, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "human:unsafe-action",
        "Human unsafe action",
        kind: .humanGate,
        position: CGPoint(x: 640, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "human:missing-merge-evidence",
        "Missing merge evidence",
        kind: .humanGate,
        position: CGPoint(x: 900, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "supervisor:merge-deny:checks-green",
        "Checks not green",
        kind: .supervisorRule,
        position: CGPoint(x: 1160, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "supervisor:merge-deny:branch-protection",
        "Branch protection blocked",
        kind: .supervisorRule,
        position: CGPoint(x: 1420, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "supervisor:merge-deny:reviewer-approved",
        "Reviewer not approved",
        kind: .supervisorRule,
        position: CGPoint(x: 1680, y: 520),
        groupID: "terminal"
      ),
      fixtureNode(
        "supervisor:merge-deny:requested-changes",
        "Requested changes",
        kind: .supervisorRule,
        position: CGPoint(x: 1030, y: 780),
        groupID: "terminal"
      ),
      fixtureNode(
        "consensus:protected-path",
        "Consensus protected path",
        kind: .consensusGate,
        position: CGPoint(x: 1290, y: 780),
        groupID: "terminal"
      ),
      fixtureNode(
        "dry_run:high-risk-merge",
        "Dry-run high risk",
        kind: .dryRunGate,
        position: CGPoint(x: 1550, y: 780),
        groupID: "terminal"
      ),
      fixtureNode(
        "supervisor:auto-merge",
        "Auto merge",
        kind: .supervisorRule,
        position: CGPoint(x: 1810, y: 780),
        groupID: "terminal"
      ),
    ]

    let edges = [
      fixtureEdge("edge:default", "action:router", "default", "supervisor:default-allow", "in", label: "action in"),
      fixtureEdge("edge:mutate", "action:router", "mutate", "dry_run:mutate_repo", "in", label: "action in"),
      fixtureEdge("edge:unsafe", "action:router", "unsafe", "human:unsafe-action", "in", label: "action in"),
      fixtureEdge("edge:merge", "action:router", "merge", "switch:merge:checks-green", "in", label: "action in"),
      fixtureEdge("edge:merge:checks-green:missing", "switch:merge:checks-green", "case_1", "human:missing-merge-evidence", "in", label: "missing"),
      fixtureEdge("edge:merge:checks-green:green", "switch:merge:checks-green", "case_2", "switch:merge:branch-protection", "in", label: "green"),
      fixtureEdge("edge:merge:checks-green:default", "switch:merge:checks-green", "default", "supervisor:merge-deny:checks-green", "in", label: "not green"),
      fixtureEdge("edge:merge:branch-protection:missing", "switch:merge:branch-protection", "case_1", "human:missing-merge-evidence", "in", label: "missing"),
      fixtureEdge("edge:merge:branch-protection:allowed", "switch:merge:branch-protection", "case_2", "switch:merge:reviewer-approved", "in", label: "allowed"),
      fixtureEdge("edge:merge:branch-protection:default", "switch:merge:branch-protection", "default", "supervisor:merge-deny:branch-protection", "in", label: "blocked"),
      fixtureEdge("edge:merge:reviewer-approved:missing", "switch:merge:reviewer-approved", "case_1", "human:missing-merge-evidence", "in", label: "missing"),
      fixtureEdge("edge:merge:reviewer-approved:approved", "switch:merge:reviewer-approved", "case_2", "switch:merge:requested-changes", "in", label: "approved"),
      fixtureEdge("edge:merge:reviewer-approved:default", "switch:merge:reviewer-approved", "default", "supervisor:merge-deny:reviewer-approved", "in", label: "not approved"),
      fixtureEdge("edge:merge:requested-changes:missing", "switch:merge:requested-changes", "case_1", "human:missing-merge-evidence", "in", label: "missing"),
      fixtureEdge("edge:merge:requested-changes:clear", "switch:merge:requested-changes", "case_2", "switch:merge:protected-path", "in", label: "clear"),
      fixtureEdge("edge:merge:requested-changes:default", "switch:merge:requested-changes", "default", "supervisor:merge-deny:requested-changes", "in", label: "changes requested"),
      fixtureEdge("edge:merge:protected-path:missing", "switch:merge:protected-path", "case_1", "human:missing-merge-evidence", "in", label: "missing"),
      fixtureEdge("edge:merge:protected-path:clear", "switch:merge:protected-path", "case_2", "risk:merge", "in", label: "clear"),
      fixtureEdge("edge:merge:protected-path:default", "switch:merge:protected-path", "default", "consensus:protected-path", "in", label: "touched"),
      fixtureEdge("edge:risk-low", "risk:merge", "low_or_equal", "supervisor:auto-merge", "in", label: "low risk"),
      fixtureEdge("edge:risk-high", "risk:merge", "high", "dry_run:high-risk-merge", "in", label: "high risk"),
      fixtureEdge("edge:risk-missing", "risk:merge", "missing", "human:missing-merge-evidence", "in", label: "missing"),
    ]

    let groups = fixtureGroups(
      [
        ("entry", "Action routing", .intake, ["action:router"]),
        (
          "merge",
          "Merge checks",
          .evaluation,
          [
            "switch:merge:checks-green",
            "switch:merge:branch-protection",
            "switch:merge:reviewer-approved",
            "switch:merge:requested-changes",
            "switch:merge:protected-path",
            "risk:merge",
          ]
        ),
        (
          "terminal",
          "Terminal decisions",
          .release,
          [
            "supervisor:default-allow",
            "dry_run:mutate_repo",
            "human:unsafe-action",
            "human:missing-merge-evidence",
            "supervisor:merge-deny:checks-green",
            "supervisor:merge-deny:branch-protection",
            "supervisor:merge-deny:reviewer-approved",
            "supervisor:merge-deny:requested-changes",
            "consensus:protected-path",
            "dry_run:high-risk-merge",
            "supervisor:auto-merge",
          ]
        ),
      ],
      nodes: nodes
    )

    return Self(id: "default", nodes: nodes, groups: groups, edges: edges)
  }()

  static let multiGroup: Self = {
    let nodes = [
      fixtureNode("mg-pre", "Pre-check", kind: .ifThenElse, position: CGPoint(x: 120, y: 260), groupID: "intake", outputs: ["then", "else"]),
      fixtureNode("intake", "Intake gate", kind: .actionGate, position: CGPoint(x: 360, y: 260), groupID: "intake", inputs: ["in"], outputs: ["review", "deploy"]),
      fixtureNode("rv-switch", "Review switch", kind: .switch, position: CGPoint(x: 760, y: 140), groupID: "review", inputs: ["in"], outputs: ["pass", "escalate", "default"]),
      fixtureNode("rv-evidence", "Review evidence", kind: .evidenceCheck, position: CGPoint(x: 1000, y: 140), groupID: "review", inputs: ["in"], outputs: ["pass", "fail", "missing"]),
      fixtureNode("rv-ifelse", "Conflicts clear?", kind: .ifThenElse, position: CGPoint(x: 760, y: 360), groupID: "review", inputs: ["in"], outputs: ["then", "else"]),
      fixtureNode("rv-consensus", "Consensus", kind: .consensusGate, position: CGPoint(x: 1000, y: 360), groupID: "review", inputs: ["in"], outputs: ["out"]),
      fixtureNode("dp-risk", "Deploy risk", kind: .riskClassifier, position: CGPoint(x: 760, y: 620), groupID: "deploy", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]),
      fixtureNode("dp-wait", "Wait for checks", kind: .waitStep, position: CGPoint(x: 1000, y: 620), groupID: "deploy", inputs: ["in"], outputs: ["out"]),
      fixtureNode("dp-evidence", "Deploy evidence", kind: .evidenceCheck, position: CGPoint(x: 760, y: 840), groupID: "deploy", inputs: ["in"], outputs: ["pass", "fail", "missing"]),
      fixtureNode("dp-action", "Deploy action", kind: .actionStep, position: CGPoint(x: 1000, y: 840), groupID: "deploy", inputs: ["in"], outputs: ["out"]),
      fixtureNode("out-human", "Human gate", kind: .humanGate, position: CGPoint(x: 1420, y: 220), groupID: "outcomes"),
      fixtureNode("out-allow", "Allow", kind: .supervisorRule, position: CGPoint(x: 1680, y: 220), groupID: "outcomes"),
      fixtureNode("out-deny", "Deny", kind: .supervisorRule, position: CGPoint(x: 1420, y: 620), groupID: "outcomes"),
      fixtureNode("out-finish", "Finish", kind: .finish, position: CGPoint(x: 1680, y: 620), groupID: "outcomes"),
    ]

    let edges = [
      fixtureEdge("e:pre-intake", "mg-pre", "then", "intake", "in", label: "open"),
      fixtureEdge("e:pre-deny", "mg-pre", "else", "out-deny", "in", label: "closed"),
      fixtureEdge("e:in-rv", "intake", "review", "rv-switch", "in", label: "review"),
      fixtureEdge("e:in-dp", "intake", "deploy", "dp-risk", "in", label: "deploy"),
      fixtureEdge("e:rvs-pass", "rv-switch", "pass", "rv-evidence", "in", label: "review ok"),
      fixtureEdge("e:rvs-esc", "rv-switch", "escalate", "out-human", "in", label: "escalate"),
      fixtureEdge("e:rvs-def", "rv-switch", "default", "out-deny", "in", label: "reject"),
      fixtureEdge("e:rv-pass", "rv-evidence", "pass", "rv-ifelse", "in", label: "approved"),
      fixtureEdge("e:rv-fail", "rv-evidence", "fail", "out-deny", "in", label: "deny"),
      fixtureEdge("e:rv-missing", "rv-evidence", "missing", "out-human", "in", label: "missing"),
      fixtureEdge("e:rv-then", "rv-ifelse", "then", "rv-consensus", "in", label: "no conflicts"),
      fixtureEdge("e:rv-else", "rv-ifelse", "else", "out-human", "in", label: "conflicts"),
      fixtureEdge("e:rv-allow", "rv-consensus", "out", "out-allow", "in", label: "allow"),
      fixtureEdge("e:dp-low", "dp-risk", "low_or_equal", "dp-wait", "in", label: "low risk"),
      fixtureEdge("e:dp-high", "dp-risk", "high", "out-deny", "in", label: "deny"),
      fixtureEdge("e:dp-missing", "dp-risk", "missing", "out-human", "in", label: "missing"),
      fixtureEdge("e:dp-wait-ev", "dp-wait", "out", "dp-evidence", "in", label: "resumed"),
      fixtureEdge("e:dp-pass", "dp-evidence", "pass", "dp-action", "in", label: "branch ok"),
      fixtureEdge("e:dp-fail", "dp-evidence", "fail", "out-deny", "in", label: "deny"),
      fixtureEdge("e:dp-ev-missing", "dp-evidence", "missing", "out-human", "in", label: "missing"),
      fixtureEdge("e:dp-finish", "dp-action", "out", "out-finish", "in", label: "deployed"),
    ]

    let groups = fixtureGroups(
      [
        ("intake", "Intake", .intake, ["mg-pre", "intake"]),
        ("review", "Review lane", .evaluation, ["rv-switch", "rv-evidence", "rv-ifelse", "rv-consensus"]),
        ("deploy", "Deploy lane", .evaluation, ["dp-risk", "dp-wait", "dp-evidence", "dp-action"]),
        ("outcomes", "Outcomes", .release, ["out-human", "out-allow", "out-deny", "out-finish"]),
      ],
      nodes: nodes
    )

    return Self(id: "multi-group", nodes: nodes, groups: groups, edges: edges)
  }()

  static let extreme: Self = {
    let nodes = [
      fixtureNode("x-entry", "Workflow entry", kind: .workflowEntry, position: CGPoint(x: 120, y: 120), groupID: "x-intake", inputs: [], outputs: ["out"]),
      fixtureNode("x-trigger", "Trigger", kind: .trigger, position: CGPoint(x: 120, y: 360), groupID: "x-intake", inputs: [], outputs: ["event"]),
      fixtureNode("x-route", "Action gate", kind: .actionGate, position: CGPoint(x: 380, y: 240), groupID: "x-intake", inputs: ["in"], outputs: ["merge", "review", "mutate", "agent", "verify"]),
      fixtureNode("x-evidence", "Merge evidence", kind: .evidenceCheck, position: CGPoint(x: 760, y: 120), groupID: "x-checks", inputs: ["in"], outputs: ["pass", "fail", "missing"]),
      fixtureNode("x-switch", "Review switch", kind: .switch, position: CGPoint(x: 760, y: 360), groupID: "x-checks", inputs: ["in"], outputs: ["case_open", "case_draft", "default"]),
      fixtureNode("x-ifelse", "Conflicts?", kind: .ifThenElse, position: CGPoint(x: 1020, y: 120), groupID: "x-checks", inputs: ["in"], outputs: ["then", "else"]),
      fixtureNode("x-risk-merge", "Merge risk", kind: .riskClassifier, position: CGPoint(x: 1020, y: 360), groupID: "x-checks", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]),
      fixtureNode("x-wait", "Wait for checks", kind: .waitStep, position: CGPoint(x: 1400, y: 120), groupID: "x-orchestration", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-event", "Event wait", kind: .eventWait, position: CGPoint(x: 1400, y: 360), groupID: "x-orchestration", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-merge-step", "Merge action", kind: .actionStep, position: CGPoint(x: 1660, y: 120), groupID: "x-orchestration", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-handoff", "Handoff to deploy", kind: .handoff, position: CGPoint(x: 1660, y: 360), groupID: "x-orchestration", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-agent-risk", "Agent risk", kind: .riskClassifier, position: CGPoint(x: 1400, y: 700), groupID: "x-agent", inputs: ["in"], outputs: ["low_or_equal", "high", "missing"]),
      fixtureNode("x-agent-step", "Spawn agent", kind: .actionStep, position: CGPoint(x: 1660, y: 700), groupID: "x-agent", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-agent-handoff", "Agent handoff", kind: .handoff, position: CGPoint(x: 1920, y: 700), groupID: "x-agent", inputs: ["in"], outputs: ["out"]),
      fixtureNode("x-human", "Human gate", kind: .humanGate, position: CGPoint(x: 2180, y: 160), groupID: "x-gates"),
      fixtureNode("x-consensus", "Consensus gate", kind: .consensusGate, position: CGPoint(x: 2180, y: 420), groupID: "x-gates", outputs: ["out"]),
      fixtureNode("x-dryrun", "Dry-run gate", kind: .dryRunGate, position: CGPoint(x: 2180, y: 680), groupID: "x-gates", outputs: ["out"]),
      fixtureNode("x-allow", "Allow merge", kind: .supervisorRule, position: CGPoint(x: 2460, y: 120), groupID: "x-terminals", outputs: ["out"]),
      fixtureNode("x-deny", "Deny merge", kind: .supervisorRule, position: CGPoint(x: 2460, y: 360), groupID: "x-terminals"),
      fixtureNode("x-deploy", "Deploy", kind: .supervisorRule, position: CGPoint(x: 2460, y: 600), groupID: "x-terminals"),
      fixtureNode("x-finish", "Finish", kind: .finish, position: CGPoint(x: 2720, y: 360), groupID: "x-terminals"),
    ]

    let edges = [
      fixtureEdge("x-entry-route", "x-entry", "out", "x-route", "in", label: "entry"),
      fixtureEdge("x-trigger-route", "x-trigger", "event", "x-route", "in", label: "trigger"),
      fixtureEdge("x-route-merge", "x-route", "merge", "x-evidence", "in", label: "merge"),
      fixtureEdge("x-route-review", "x-route", "review", "x-switch", "in", label: "review"),
      fixtureEdge("x-route-mutate", "x-route", "mutate", "x-dryrun", "in", label: "mutate"),
      fixtureEdge("x-route-agent", "x-route", "agent", "x-agent-risk", "in", label: "agent"),
      fixtureEdge("x-evidence-pass", "x-evidence", "pass", "x-switch", "in", label: "checks ok"),
      fixtureEdge("x-evidence-fail", "x-evidence", "fail", "x-deny", "in", label: "checks fail"),
      fixtureEdge("x-evidence-missing", "x-evidence", "missing", "x-human", "in", label: "missing"),
      fixtureEdge("x-switch-open", "x-switch", "case_open", "x-ifelse", "in", label: "open"),
      fixtureEdge("x-switch-draft", "x-switch", "case_draft", "x-human", "in", label: "draft"),
      fixtureEdge("x-switch-default", "x-switch", "default", "x-deny", "in", label: "default"),
      fixtureEdge("x-ifelse-then", "x-ifelse", "then", "x-risk-merge", "in", label: "no conflicts"),
      fixtureEdge("x-ifelse-else", "x-ifelse", "else", "x-consensus", "in", label: "conflicts"),
      fixtureEdge("x-risk-low", "x-risk-merge", "low_or_equal", "x-wait", "in", label: "low risk"),
      fixtureEdge("x-risk-high", "x-risk-merge", "high", "x-dryrun", "in", label: "high risk"),
      fixtureEdge("x-risk-missing", "x-risk-merge", "missing", "x-human", "in", label: "missing"),
      fixtureEdge("x-wait-event", "x-wait", "out", "x-event", "in", label: "checks ready"),
      fixtureEdge("x-event-merge", "x-event", "out", "x-merge-step", "in", label: "resume"),
      fixtureEdge("x-merge-handoff", "x-merge-step", "out", "x-handoff", "in", label: "merged"),
      fixtureEdge("x-handoff-deploy", "x-handoff", "out", "x-deploy", "in", label: "deploy"),
      fixtureEdge("x-agent-low", "x-agent-risk", "low_or_equal", "x-agent-step", "in", label: "spawn"),
      fixtureEdge("x-agent-high", "x-agent-risk", "high", "x-human", "in", label: "agent risk"),
      fixtureEdge("x-agent-missing", "x-agent-risk", "missing", "x-human", "in", label: "agent missing"),
      fixtureEdge("x-agent-step-handoff", "x-agent-step", "out", "x-agent-handoff", "in", label: "agent ready"),
      fixtureEdge("x-agent-handoff-consensus", "x-agent-handoff", "out", "x-consensus", "in", label: "agent review"),
      fixtureEdge("x-consensus-allow", "x-consensus", "out", "x-allow", "in", label: "approved"),
      fixtureEdge("x-dryrun-finish", "x-dryrun", "out", "x-finish", "in", label: "dry run"),
      fixtureEdge("x-allow-finish", "x-allow", "out", "x-finish", "in", label: "complete"),
    ]

    let groups = fixtureGroups(
      [
        ("x-intake", "Intake", .intake, ["x-entry", "x-trigger", "x-route"]),
        ("x-checks", "Checks", .evaluation, ["x-evidence", "x-switch", "x-ifelse", "x-risk-merge"]),
        ("x-orchestration", "Orchestration", .evaluation, ["x-wait", "x-event", "x-merge-step", "x-handoff"]),
        ("x-agent", "Agent lane", .evaluation, ["x-agent-risk", "x-agent-step", "x-agent-handoff"]),
        ("x-gates", "Gates", .release, ["x-human", "x-consensus", "x-dryrun"]),
        ("x-terminals", "Terminals", .release, ["x-allow", "x-deny", "x-deploy", "x-finish"]),
      ],
      nodes: nodes
    )

    return Self(id: "extreme", nodes: nodes, groups: groups, edges: edges)
  }()
}

private func fixtureNode(
  _ id: String,
  _ title: String,
  kind: PolicyCanvasNodeKind,
  position: CGPoint,
  groupID: String,
  inputs: [String] = ["in"],
  outputs: [String] = []
) -> PolicyCanvasNode {
  var node = PolicyCanvasNode(id: id, title: title, kind: kind, position: position)
  node.groupID = groupID
  node.inputPorts = inputs.map { portTitle in
    PolicyCanvasPort(
      id: "\(PolicyCanvasPortKind.input.rawValue)-\(portTitle)",
      title: portTitle,
      kind: .input
    )
  }
  node.outputPorts = outputs.map { portTitle in
    PolicyCanvasPort(
      id: "\(PolicyCanvasPortKind.output.rawValue)-\(portTitle)",
      title: portTitle,
      kind: .output
    )
  }
  return node
}

private func fixtureEdge(
  _ id: String,
  _ sourceNodeID: String,
  _ sourcePortTitle: String,
  _ targetNodeID: String,
  _ targetPortTitle: String,
  label: String
) -> PolicyCanvasEdge {
  PolicyCanvasEdge(
    id: id,
    source: PolicyCanvasPortEndpoint(
      nodeID: sourceNodeID,
      portID: "\(PolicyCanvasPortKind.output.rawValue)-\(sourcePortTitle)",
      kind: .output
    ),
    target: PolicyCanvasPortEndpoint(
      nodeID: targetNodeID,
      portID: "\(PolicyCanvasPortKind.input.rawValue)-\(targetPortTitle)",
      kind: .input
    ),
    label: label
  )
}

private func fixtureGroups(
  _ definitions: [(id: String, title: String, tone: PolicyCanvasGroupTone, nodeIDs: [String])],
  nodes: [PolicyCanvasNode]
) -> [PolicyCanvasGroup] {
  definitions.map { definition in
    let members = nodes.filter { definition.nodeIDs.contains($0.id) }
    return PolicyCanvasGroup(
      id: definition.id,
      title: definition.title,
      frame: policyCanvasGroupFrame(containing: members) ?? .zero,
      tone: definition.tone
    )
  }
}

private func policyCanvasGraphHull(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> CGRect {
  (nodes.map(policyCanvasNodeFrame) + policyCanvasGroupTitleFrames(groups)).reduce(into: CGRect.null) {
    partial,
    frame in
    partial = partial.union(frame)
  }
}

private func policyCanvasRouteHull(
  routes: [String: PolicyCanvasEdgeRoute]
) -> CGRect {
  routes.values.reduce(into: CGRect.null) { partial, route in
    partial = partial.union(policyCanvasPolylineBounds(route.points))
  }
}

private func policyCanvasPolylineBounds(_ points: [CGPoint]) -> CGRect {
  guard let first = points.first else {
    return .null
  }
  return points.dropFirst().reduce(into: CGRect(origin: first, size: .zero)) { partial, point in
    partial = partial.union(CGRect(origin: point, size: .zero))
  }
}

private func policyCanvasIncompatibleSharedPairs(
  _ evaluation: PolicyCanvasCanonicalFixtureEvaluation
) throws -> [(leftID: String, rightID: String, sharedOverlap: CGFloat)] {
  let prepared = PolicyCanvasPreparedRouteInput(
    input: PolicyCanvasRouteWorkerInput(
      nodes: evaluation.nodes,
      groups: evaluation.groups,
      edges: evaluation.edges,
      fontScale: 1,
      routingHints: evaluation.routingHints,
      algorithmSelection: .harnessCurrent
    )
  )
  let nodeIndex = prepared.nodeIndex
  let edgeByID = Dictionary(uniqueKeysWithValues: evaluation.edges.map { ($0.id, $0) })
  let orderedIDs = evaluation.edges.map(\.id)
  var overlaps: [(String, String, CGFloat)] = []

  for leftIndex in orderedIDs.indices {
    let leftID = orderedIDs[leftIndex]
    let leftEdge = try #require(edgeByID[leftID])
    let leftRoute = try #require(evaluation.routes[leftID])
    let leftLineSpacing = prepared.edgeLineSpacing(for: leftEdge, nodeIndex: nodeIndex)
    let leftKey = policyCanvasCorridorComparisonKey(
      hint: evaluation.routingHints?.edgeHint(for: leftID),
      lineSpacing: leftLineSpacing
    )

    for rightIndex in orderedIDs.index(after: leftIndex)..<orderedIDs.endIndex {
      let rightID = orderedIDs[rightIndex]
      let rightEdge = try #require(edgeByID[rightID])
      let rightRoute = try #require(evaluation.routes[rightID])
      let rightLineSpacing = prepared.edgeLineSpacing(for: rightEdge, nodeIndex: nodeIndex)
      let rightKey = policyCanvasCorridorComparisonKey(
        hint: evaluation.routingHints?.edgeHint(for: rightID),
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
        continue
      }
      let overlap = policyCanvasRouteMaxInteriorSharedOverlap(
        leftRoute,
        with: [rightRoute]
      )
      if overlap > PolicyCanvasLayout.gridSize {
        overlaps.append((leftID, rightID, overlap))
      }
    }
  }

  return overlaps
}
