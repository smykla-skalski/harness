import OSLog
import SwiftUI

private let policyCanvasRouteComputationSignposter = OSSignposter(
  subsystem: "io.harnessmonitor",
  category: "policy-canvas.perf"
)
private let policyCanvasSinglePassSeededRoutingThreshold = 1_000

struct PolicyCanvasDisplayedRoutePassContext: Sendable {
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let obstacles: [CGRect]
  let portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
  let orderedEdges: [PolicyCanvasEdge]
  let terminalSlots: [String: PolicyCanvasRouteEndpointSlots]
  let familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  let edgeLanes: [String: Int]
  let sourceFanoutLanes: [String: Int]
  let targetFanoutLanes: [String: Int]
}

public struct PolicyCanvasPreparedRouteComputation: Equatable, Sendable {
  public let routes: [String: PolicyCanvasEdgeRoute]
  public let labelPositions: [String: CGPoint]
  public let portVisibility: PolicyCanvasPortVisibilityMap
  public let portMarkerLayout: PolicyCanvasPortMarkerLayout
  public let visibleBounds: CGRect

  public init(
    routes: [String: PolicyCanvasEdgeRoute],
    labelPositions: [String: CGPoint],
    portVisibility: PolicyCanvasPortVisibilityMap,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    visibleBounds: CGRect
  ) {
    self.routes = routes
    self.labelPositions = labelPositions
    self.portVisibility = portVisibility
    self.portMarkerLayout = portMarkerLayout
    self.visibleBounds = visibleBounds
  }
}

extension PolicyCanvasPreparedRouteInput {
  public func routeComputation(
    router defaultRouter: any PolicyCanvasEdgeRouter,
    algorithmSelection: PolicyCanvasAlgorithmSelection
  ) -> PolicyCanvasPreparedRouteComputation {
    let nodeIndex = nodeIndex
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      algorithmSelection.algorithmID(for: .edgeRouting)
        == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? defaultRouter
      : algorithms.edgeRouter
    if let precomputed = precomputedRouteComputation(
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    ) {
      return precomputed
    }
    let convergenceSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let convergenceInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.converge",
      id: convergenceSignpostID,
      "nodes=\(nodes.count, privacy: .public) edges=\(edges.count, privacy: .public)"
    )
    let routeState = policyCanvasConvergedRouteState(
      prepared: self,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.converge",
      convergenceInterval,
      "routes=\(routeState.routes.count, privacy: .public)"
    )

    let postProcessSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let postProcessInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.post_process",
      id: postProcessSignpostID,
      "routes=\(routeState.routes.count, privacy: .public)"
    )
    let processedRoutes = algorithms.routePostProcessing.processRoutes(
      input: PolicyCanvasRoutePostProcessingInput(prepared: self, routes: routeState.routes)
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.post_process",
      postProcessInterval,
      "routes=\(processedRoutes.count, privacy: .public)"
    )

    let terminalsSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let terminalsInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.terminals",
      id: terminalsSignpostID,
      "routes=\(processedRoutes.count, privacy: .public)"
    )
    let terminalRoutes = policyCanvasRoutesPreservingRouteTerminals(
      original: routeState.routes,
      processed: processedRoutes
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: terminalRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalState =
      repairedRoutes == terminalRoutes
      ? PolicyCanvasRouteComputationState(
        routes: terminalRoutes,
        portMarkerLayout: routeState.portMarkerLayout
      )
      : routesReroutingBalancedPortMarkers(
        routes: repairedRoutes,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
    let routes = routesClearingCorridorReuse(
      routes: terminalState.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalOrderedRoutes = routesRepairingFinalTerminalOrder(
      routes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let finalRoutes = routesClearingCorridorsAndRestoringTerminalLeads(
      routes: terminalOrderedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let portMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: finalRoutes,
      nodeIndex: nodeIndex
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.terminals",
      terminalsInterval,
      "routes=\(finalRoutes.count, privacy: .public)"
    )

    let labelSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let labelInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.labels",
      id: labelSignpostID,
      "routes=\(finalRoutes.count, privacy: .public)"
    )
    let labelPositions = algorithms.labelPlacement.placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: finalRoutes)
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.labels",
      labelInterval,
      "labels=\(labelPositions.count, privacy: .public)"
    )

    let boundsSignpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let boundsInterval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.bounds",
      id: boundsSignpostID,
      "routes=\(finalRoutes.count, privacy: .public) labels=\(labelPositions.count, privacy: .public)"
    )
    let visibleBounds = visibleBounds(routes: finalRoutes, labelPositions: labelPositions)
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.bounds",
      boundsInterval,
      "width=\(visibleBounds.width, privacy: .public) height=\(visibleBounds.height, privacy: .public)"
    )
    return PolicyCanvasPreparedRouteComputation(
      routes: finalRoutes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: finalRoutes, nodeIndex: nodeIndex),
      portMarkerLayout: portMarkerLayout,
      visibleBounds: visibleBounds
    )
  }

  private func precomputedRouteComputation(
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasPreparedRouteComputation? {
    guard let precomputedRoutes else {
      return nil
    }
    let edgeIDs = Set(edges.map(\.id))
    guard precomputedRoutes.routes.count == edgeIDs.count,
      Set(precomputedRoutes.routes.keys) == edgeIDs
    else {
      return nil
    }
    let bodySafeRoutes = precomputedRoutesRepairingBodyHits(
      routes: precomputedRoutes.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalSafeRoutes = precomputedRoutesNormalizingTerminalStubs(
      routes: bodySafeRoutes,
      nodeIndex: nodeIndex
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: terminalSafeRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalState = routesBalancingPrecomputedPortMarkers(
      routes: repairedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let routes = routesClearingCorridorReuse(
      routes: terminalState.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let portMarkerLayout = terminalState.portMarkerLayout
    let crossedPortRoutes = routesRepairingFinalTerminalOrder(
      routes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      portMarkerLayout: portMarkerLayout
    )
    let finalRoutes = routesClearingCorridorsAndRestoringTerminalLeads(
      routes: crossedPortRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let finalPortMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: finalRoutes,
      nodeIndex: nodeIndex
    )
    let labelPositions = PolicyCanvasPolylineMidpointLabelPlacement().placeLabels(
      input: PolicyCanvasLabelPlacementInput(prepared: self, routes: finalRoutes)
    )
    return PolicyCanvasPreparedRouteComputation(
      routes: finalRoutes,
      labelPositions: labelPositions,
      portVisibility: portVisibility(routes: finalRoutes, nodeIndex: nodeIndex),
      portMarkerLayout: finalPortMarkerLayout,
      visibleBounds: visibleBounds(routes: finalRoutes, labelPositions: labelPositions)
    )
  }

  private func precomputedRoutesNormalizingTerminalStubs(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    portMarkerLayout explicitLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let markerLayout =
      explicitLayout
      ?? precomputedRouteTerminalPortMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let context = PolicyCanvasTerminalRepairContext(
      portMarkerLayout: markerLayout,
      nodeIndex: nodeIndex
    )
    var normalized = routes
    for edge in edges {
      guard var route = normalized[edge.id] else {
        continue
      }
      let currentScore = precomputedRouteTerminalMismatchScore(
        edge: edge,
        route: route,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      )
      guard currentScore > 0 else {
        continue
      }
      let currentBodyHits = precomputedBodyHits(
        edge: edge,
        route: route,
        nodeIndex: nodeIndex
      ).count
      var state = PolicyCanvasTerminalSnapState(
        score: currentScore,
        bodyHits: currentBodyHits
      )
      for role in [PolicyCanvasRouteEndpointRole.source, .target] {
        var candidateState = state
        let candidate = routeAcceptingTerminalSnap(
          edge: edge,
          route: route,
          role: role,
          context: context,
          state: &candidateState
        )
        guard candidate != route else {
          continue
        }
        route = candidate
        state = candidateState
        normalized[edge.id] = route
      }
    }
    return normalized
  }

  private func routeAcceptingTerminalSnap(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    context: PolicyCanvasTerminalRepairContext,
    state: inout PolicyCanvasTerminalSnapState
  ) -> PolicyCanvasEdgeRoute {
    let endpoint = role == .source ? edge.source : edge.target
    guard
      let markerPoint = portMarkerPoint(
        edgeID: edge.id,
        role: role,
        endpoint: endpoint,
        portMarkerLayout: context.portMarkerLayout,
        nodeIndex: context.nodeIndex
      )
    else {
      return route
    }
    let candidate = routeMovingTerminal(
      route,
      role: role,
      side: markerPoint.side,
      point: markerPoint.point
    )
    let score = precomputedRouteTerminalMismatchScore(
      edge: edge,
      route: candidate,
      portMarkerLayout: context.portMarkerLayout,
      nodeIndex: context.nodeIndex
    )
    guard score < state.score else {
      return route
    }
    let hitCount = precomputedBodyHits(
      edge: edge,
      route: candidate,
      nodeIndex: context.nodeIndex
    ).count
    guard hitCount <= state.bodyHits else {
      return route
    }
    state.score = score
    state.bodyHits = hitCount
    return candidate
  }

  private func routesRestoringTerminalLeadSides(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    preservingInterior: Bool = false
  ) -> [String: PolicyCanvasEdgeRoute] {
    var repaired = routes
    let markerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    for edge in edges {
      guard var route = repaired[edge.id] else {
        continue
      }
      if let sourcePoint = portMarkerPoint(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeRestoringTerminalLeadSide(
          route,
          role: .source,
          side: sourcePoint.side,
          point: sourcePoint.point,
          preservingInterior: preservingInterior
        )
      }
      if let targetPoint = portMarkerPoint(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        portMarkerLayout: markerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeRestoringTerminalLeadSide(
          route,
          role: .target,
          side: targetPoint.side,
          point: targetPoint.point,
          preservingInterior: preservingInterior
        )
      }
      repaired[edge.id] = route
    }
    return repaired
  }

  private func routeRestoringTerminalLeadSide(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint,
    preservingInterior: Bool
  ) -> PolicyCanvasEdgeRoute {
    if preservingInterior {
      return routeRestoringTerminalStubOnly(route, role: role, side: side, point: point)
    }
    return routeMovingTerminal(route, role: role, side: side, point: point)
  }

  private func routeRestoringTerminalStubOnly(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 2 else {
      return route
    }
    let currentSide =
      switch role {
      case .source: policyCanvasRouteSourceSide(route)
      case .target: policyCanvasRouteTargetSide(route)
      }
    guard currentSide != side else {
      return route
    }
    let lead = policyCanvasPortLeadPoint(point, side: side)
    var points: [CGPoint] = []
    switch role {
    case .source:
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      for oldPoint in route.points.dropFirst() {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
    case .target:
      for oldPoint in route.points.dropLast() {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
      while let last = points.last, last == point || last == lead {
        points.removeLast()
      }
      policyCanvasAppendOrthogonalBridgePreservingCurrentLane(lead, to: &points)
      policyCanvasAppendOrthogonalBridge(point, to: &points)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func policyCanvasAppendOrthogonalBridgePreservingCurrentLane(
    _ point: CGPoint,
    to points: inout [CGPoint]
  ) {
    guard let last = points.last else {
      points.append(point)
      return
    }
    if abs(last.x - point.x) > 0.001, abs(last.y - point.y) > 0.001 {
      points.append(CGPoint(x: last.x, y: point.y))
    }
    if points.last != point {
      points.append(point)
    }
  }

  private func precomputedRouteTerminalMismatchScore(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Int {
    let context = PolicyCanvasTerminalRepairContext(
      portMarkerLayout: portMarkerLayout,
      nodeIndex: nodeIndex
    )
    return precomputedRouteTerminalMismatchScore(
      PolicyCanvasTerminalMismatchInput(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        routePoint: route.points.first,
        leadPoint: route.points.dropFirst().first,
        routeSide: policyCanvasRouteSourceSide(route)
      ),
      context: context
    )
      + precomputedRouteTerminalMismatchScore(
        PolicyCanvasTerminalMismatchInput(
          edgeID: edge.id,
          role: .target,
          endpoint: edge.target,
          routePoint: route.points.last,
          leadPoint: route.points.dropLast().last,
          routeSide: policyCanvasRouteTargetSide(route)
        ),
        context: context
      )
  }

  private func precomputedRouteTerminalMismatchScore(
    _ input: PolicyCanvasTerminalMismatchInput,
    context: PolicyCanvasTerminalRepairContext
  ) -> Int {
    guard
      let markerPoint = portMarkerPoint(
        edgeID: input.edgeID,
        role: input.role,
        endpoint: input.endpoint,
        portMarkerLayout: context.portMarkerLayout,
        nodeIndex: context.nodeIndex
      )
    else {
      return 0
    }
    var score = 0
    if input.routeSide != markerPoint.side {
      score += 10_000
    }
    guard let routePoint = input.routePoint else {
      return score + 10_000
    }
    let distance =
      abs(routePoint.x - markerPoint.point.x)
      + abs(routePoint.y - markerPoint.point.y)
    if distance > 0.5 {
      score += Int(ceil(distance * 10))
    }
    let expectedLead = policyCanvasPortLeadPoint(markerPoint.point, side: markerPoint.side)
    if let leadPoint = input.leadPoint {
      let leadDistance = abs(leadPoint.x - expectedLead.x) + abs(leadPoint.y - expectedLead.y)
      if leadDistance > 0.5 {
        score += Int(ceil(leadDistance * 10))
      }
    } else {
      score += 10_000
    }
    return score
  }

  private func routesRepairingFinalTerminalOrder(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet,
    portMarkerLayout: PolicyCanvasPortMarkerLayout? = nil
  ) -> [String: PolicyCanvasEdgeRoute] {
    let terminalSafeRoutes = precomputedRoutesNormalizingTerminalStubs(
      routes: routes,
      nodeIndex: nodeIndex,
      portMarkerLayout: portMarkerLayout
    )
    return routesRepairingCrossedPortOrder(
      routes: terminalSafeRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
  }

  private func precomputedRoutesRepairingBodyHits(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let hitEdgeIDs = precomputedBodyHitEdgeIDs(routes: routes, nodeIndex: nodeIndex)
    guard !hitEdgeIDs.isEmpty else {
      return routes
    }
    let precomputedMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    let selectedRoutes = policyCanvasSelectedRoutes(
      phase: "precomputed-repair",
      portMarkerLayout: precomputedMarkerLayout,
      context: context
    )
    var repaired = routes
    for edge in edges where hitEdgeIDs.contains(edge.id) {
      guard let route = selectedRoutes[edge.id],
        precomputedBodyHits(edge: edge, route: route, nodeIndex: nodeIndex).isEmpty
      else {
        continue
      }
      repaired[edge.id] = route
    }
    return repaired
  }

  private func routesClearingCorridorReuse(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let splitter = PolicyCanvasOrthogonalNudgingRouteProcessing()
    let obstacles = routingObstacles()
    let originalBodyHits = precomputedBodyHits(routes: routes, nodeIndex: nodeIndex).count
    let edgesByID = Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    func acceptsBodySafeSplit(
      _ edgeID: String,
      _ oldRoute: PolicyCanvasEdgeRoute,
      _ newRoute: PolicyCanvasEdgeRoute
    ) -> Bool {
      guard let edge = edgesByID[edgeID] else {
        return true
      }
      let oldHitCount = precomputedBodyHits(
        edge: edge, route: oldRoute, nodeIndex: nodeIndex
      ).count
      let newHitCount = precomputedBodyHits(
        edge: edge, route: newRoute, nodeIndex: nodeIndex
      ).count
      return newHitCount <= oldHitCount
    }
    var current = routes
    var best = routes
    for _ in 0..<3 {
      let split = splitter.routesClearingRemainingCollinearReuse(
        current,
        obstacles: obstacles,
        accepts: acceptsBodySafeSplit
      )
      if precomputedBodyHits(routes: split, nodeIndex: nodeIndex).count <= originalBodyHits {
        best = split
        guard split != current else {
          break
        }
        current = split
        continue
      }
      let repaired = precomputedRoutesRepairingBodyHits(
        routes: split,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      guard precomputedBodyHits(routes: repaired, nodeIndex: nodeIndex).count <= originalBodyHits,
        repaired != current
      else {
        break
      }
      best = repaired
      current = repaired
    }
    let pairSplit = splitter.routesClearingRemainingParallelPairs(
      best,
      obstacles: obstacles,
      accepts: acceptsBodySafeSplit
    )
    guard precomputedBodyHits(routes: pairSplit, nodeIndex: nodeIndex).count <= originalBodyHits
    else {
      return best
    }
    return pairSplit
  }

  private func routesClearingCorridorsAndRestoringTerminalLeads(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    var currentRoutes = routesRestoringTerminalLeadSides(
      routes: routes,
      nodeIndex: nodeIndex
    )
    for _ in 0..<5 {
      let corridorRoutes = routesClearingCorridorReuse(
        routes: currentRoutes,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      let terminalRoutes = routesRestoringTerminalLeadSides(
        routes: corridorRoutes,
        nodeIndex: nodeIndex,
        preservingInterior: true
      )
      guard terminalRoutes != currentRoutes else {
        return terminalRoutes
      }
      currentRoutes = terminalRoutes
    }
    return routesRepairingResidualCorridorReuse(routes: currentRoutes, nodeIndex: nodeIndex)
  }

  private func routesRepairingResidualCorridorReuse(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var currentRoutes = routes
    var currentViolations = precomputedCorridorReuseViolations(routes: currentRoutes)
    var currentScore = residualCorridorReuseScore(currentViolations)
    let repairLimit = min(16, max(2, currentViolations.count * 4))
    for _ in 0..<repairLimit {
      guard let violation = currentViolations.first else {
        return currentRoutes
      }
      let currentBodyHits = precomputedBodyHits(routes: currentRoutes, nodeIndex: nodeIndex).count
      var accepted: ([String: PolicyCanvasEdgeRoute], [PolicyCanvasCorridorViolation])?
      for edgeID in [violation.edgeB, violation.edgeA] {
        guard let route = currentRoutes[edgeID] else {
          continue
        }
        for offset in residualCorridorRepairOffsets {
          guard
            let shiftedRoute = routeShiftingResidualCorridor(
              route,
              violation: violation,
              offset: offset
            )
          else {
            continue
          }
          var candidateRoutes = currentRoutes
          candidateRoutes[edgeID] = shiftedRoute
          guard precomputedTerminalSideMismatchCount(routes: candidateRoutes) == 0,
            precomputedBodyHits(routes: candidateRoutes, nodeIndex: nodeIndex).count
              <= currentBodyHits
          else {
            continue
          }
          let candidateViolations = precomputedCorridorReuseViolations(routes: candidateRoutes)
          let candidateScore = residualCorridorReuseScore(candidateViolations)
          guard residualCorridorReuseScore(candidateScore, improves: currentScore) else {
            continue
          }
          accepted = (candidateRoutes, candidateViolations)
          break
        }
        if accepted != nil {
          break
        }
      }
      guard let accepted else {
        break
      }
      currentRoutes = accepted.0
      currentViolations = accepted.1
      currentScore = residualCorridorReuseScore(currentViolations)
    }
    return currentRoutes
  }

  private func residualCorridorReuseScore(
    _ violations: [PolicyCanvasCorridorViolation]
  ) -> (count: Int, length: CGFloat) {
    (
      violations.count,
      violations.reduce(CGFloat.zero) { total, violation in
        total + residualCorridorReuseLength(violation)
      }
    )
  }

  private func residualCorridorReuseScore(
    _ candidate: (count: Int, length: CGFloat),
    improves current: (count: Int, length: CGFloat)
  ) -> Bool {
    candidate.count < current.count
      || (candidate.count == current.count && candidate.length < current.length - 0.001)
  }

  private func residualCorridorReuseLength(_ violation: PolicyCanvasCorridorViolation) -> CGFloat {
    if violation.isHorizontal {
      return abs(violation.overlapEnd.x - violation.overlapStart.x)
    }
    return abs(violation.overlapEnd.y - violation.overlapStart.y)
  }

  private var residualCorridorRepairOffsets: [CGFloat] {
    let step = PolicyCanvasVisibilityRouter.laneSpreadStep
    return [step, -step, step * 2, -(step * 2)]
  }

  private func precomputedCorridorReuseViolations(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasCorridorViolation] {
    policyCanvasMeasureCorridors(
      routedEdges: precomputedRoutedEdges(routes: routes),
      thresholds: .default
    )
    .filter { $0.kind == .collinear }
  }

  private func routeShiftingResidualCorridor(
    _ route: PolicyCanvasEdgeRoute,
    violation: PolicyCanvasCorridorViolation,
    offset: CGFloat
  ) -> PolicyCanvasEdgeRoute? {
    let points = route.points
    guard points.count >= 4 else {
      return nil
    }
    let segmentIndex = residualCorridorSegmentIndex(points, violation: violation)
    guard let segmentIndex else {
      return nil
    }
    var rebuilt: [CGPoint] = []
    var index = points.startIndex
    while index < points.endIndex {
      if index == segmentIndex {
        policyCanvasAppendOrthogonalBridge(
          residualCorridorShifted(points[index], violation: violation, offset: offset),
          to: &rebuilt
        )
        policyCanvasAppendOrthogonalBridge(
          residualCorridorShifted(
            points[points.index(after: index)], violation: violation, offset: offset),
          to: &rebuilt
        )
        index = points.index(index, offsetBy: 2)
      } else {
        policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
        index = points.index(after: index)
      }
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    guard compressed != route.points else {
      return nil
    }
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func residualCorridorSegmentIndex(
    _ points: [CGPoint],
    violation: PolicyCanvasCorridorViolation
  ) -> Int? {
    guard points.count >= 4 else {
      return nil
    }
    for index in 1..<(points.count - 2) {
      let start = points[index]
      let end = points[index + 1]
      guard residualCorridorSegmentMatches(start, end, violation: violation) else {
        continue
      }
      return index
    }
    return nil
  }

  private func residualCorridorSegmentMatches(
    _ start: CGPoint,
    _ end: CGPoint,
    violation: PolicyCanvasCorridorViolation
  ) -> Bool {
    if violation.isHorizontal {
      guard abs(start.y - end.y) <= 0.001,
        abs(start.y - violation.overlapStart.y) <= 0.001
      else {
        return false
      }
      return residualCorridorSpanOverlaps(
        start.x,
        end.x,
        violation.overlapStart.x,
        violation.overlapEnd.x
      )
    }
    guard abs(start.x - end.x) <= 0.001,
      abs(start.x - violation.overlapStart.x) <= 0.001
    else {
      return false
    }
    return residualCorridorSpanOverlaps(
      start.y,
      end.y,
      violation.overlapStart.y,
      violation.overlapEnd.y
    )
  }

  private func residualCorridorSpanOverlaps(
    _ start: CGFloat,
    _ end: CGFloat,
    _ overlapStart: CGFloat,
    _ overlapEnd: CGFloat
  ) -> Bool {
    let lower = min(start, end)
    let upper = max(start, end)
    let overlapLower = min(overlapStart, overlapEnd)
    let overlapUpper = max(overlapStart, overlapEnd)
    return min(upper, overlapUpper) - max(lower, overlapLower) >= 0.001
  }

  private func residualCorridorShifted(
    _ point: CGPoint,
    violation: PolicyCanvasCorridorViolation,
    offset: CGFloat
  ) -> CGPoint {
    if violation.isHorizontal {
      return CGPoint(x: point.x, y: PolicyCanvasLayout.routeGridRound(point.y + offset))
    }
    return CGPoint(x: PolicyCanvasLayout.routeGridRound(point.x + offset), y: point.y)
  }

  private func routesRepairingCrossedPortOrder(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let originalBodyHits = precomputedBodyHits(routes: routes, nodeIndex: nodeIndex).count
    let originalTerminalSideMismatches = precomputedTerminalSideMismatchCount(routes: routes)
    let repairContext = PolicyCanvasCrossedPortRepairContext(
      nodeIndex: nodeIndex,
      maximumBodyHits: originalBodyHits,
      maximumTerminalSideMismatches: originalTerminalSideMismatches,
      router: selectedRouter,
      algorithms: algorithms
    )
    var currentRoutes = routes
    var currentViolations = precomputedCrossedPortViolations(
      routes: currentRoutes,
      nodeIndex: nodeIndex
    )
    let repairLimit = min(24, max(6, currentViolations.count))
    for _ in 0..<repairLimit {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let groupedCandidate = routesSwappingCrossedPortPairs(
        routes: currentRoutes,
        violations: currentViolations
      )
      let groupedViolations = precomputedCrossedPortViolations(
        routes: groupedCandidate,
        nodeIndex: nodeIndex
      )
      if let acceptedGroupedCandidate = crossedPortRepairCandidate(
        candidateRoutes: groupedCandidate,
        originalRoutes: currentRoutes,
        originalViolations: currentViolations,
        candidateViolations: groupedViolations,
        context: repairContext
      ) {
        currentRoutes = acceptedGroupedCandidate.routes
        currentViolations = acceptedGroupedCandidate.violations
        continue
      }
      guard
        let singleGroupCandidate = crossedPortSingleGroupRepairCandidate(
          routes: currentRoutes,
          violations: currentViolations,
          context: repairContext
        )
      else {
        break
      }
      currentRoutes = singleGroupCandidate.routes
      currentViolations = singleGroupCandidate.violations
    }
    return currentRoutes
  }

  private func crossedPortSingleGroupRepairCandidate(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    context: PolicyCanvasCrossedPortRepairContext
  ) -> PolicyCanvasCrossedPortRepairCandidate? {
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let groupedViolations = Dictionary(grouping: violations) {
      PolicyCanvasCrossedPortGroupKey(nodeID: $0.nodeID, side: $0.side)
    }
    var best: PolicyCanvasCrossedPortRepairCandidate?
    for (key, group) in groupedViolations.sorted(by: crossedPortGroupOrder) {
      func consider(_ candidateRoutes: [String: PolicyCanvasEdgeRoute]) {
        guard
          let candidate = crossedPortRepairCandidate(
            candidateRoutes: candidateRoutes,
            originalRoutes: routes,
            originalViolations: violations,
            context: context
          )
        else { return }
        if best.map({ candidate.violations.count < $0.violations.count }) ?? true {
          best = candidate
        }
      }

      for violation in group {
        consider(
          routesSwappingCrossedPortPairTerminalChannels(
            routes: routes,
            violation: violation,
            edgesByID: edgesByID
          )
        )
      }

      let farAxisFanCandidate = routesOrderingCrossedPortTerminalFanByFarAxis(
        routes: routes,
        violations: group,
        nodeID: key.nodeID,
        side: key.side,
        edgesByID: edgesByID
      )
      consider(farAxisFanCandidate)

      consider(
        routesRebuildingCrossedPortTerminalFan(
          routes: routes,
          violations: group,
          nodeID: key.nodeID,
          side: key.side,
          edgesByID: edgesByID
        )
      )

      let laneCandidateRoutes = routesSortingCrossedPortTerminalChannels(
        routes: routes,
        violations: group,
        nodeID: key.nodeID,
        side: key.side,
        edgesByID: edgesByID
      )
      consider(laneCandidateRoutes)

      let pointCandidateRoutes = routesSortingCrossedPortGroup(
        routes: routes,
        violations: group,
        nodeID: key.nodeID,
        side: key.side,
        edgesByID: edgesByID
      )
      consider(pointCandidateRoutes)

      consider(
        routesSortingCrossedPortGroup(
          routes: laneCandidateRoutes,
          violations: group,
          nodeID: key.nodeID,
          side: key.side,
          edgesByID: edgesByID
        )
      )

    }
    return best
  }

  private func crossedPortRepairCandidate(
    candidateRoutes: [String: PolicyCanvasEdgeRoute],
    originalRoutes: [String: PolicyCanvasEdgeRoute],
    originalViolations: [PolicyCanvasCrossedPortsViolation],
    candidateViolations explicitCandidateViolations: [PolicyCanvasCrossedPortsViolation]? = nil,
    context: PolicyCanvasCrossedPortRepairContext
  ) -> PolicyCanvasCrossedPortRepairCandidate? {
    guard candidateRoutes != originalRoutes,
      precomputedTerminalSideMismatchCount(routes: candidateRoutes)
        <= context.maximumTerminalSideMismatches
    else {
      return nil
    }
    let candidateViolations =
      explicitCandidateViolations
      ?? precomputedCrossedPortViolations(routes: candidateRoutes, nodeIndex: context.nodeIndex)
    guard candidateViolations.count < originalViolations.count else {
      return nil
    }
    guard
      precomputedBodyHits(routes: candidateRoutes, nodeIndex: context.nodeIndex).count
        > context.maximumBodyHits
    else {
      return PolicyCanvasCrossedPortRepairCandidate(
        routes: candidateRoutes,
        violations: candidateViolations
      )
    }
    let bodyRepairedRoutes = precomputedRoutesRepairingBodyHits(
      routes: candidateRoutes,
      nodeIndex: context.nodeIndex,
      router: context.router,
      algorithms: context.algorithms
    )
    guard
      precomputedBodyHits(routes: bodyRepairedRoutes, nodeIndex: context.nodeIndex).count
        <= context.maximumBodyHits,
      precomputedTerminalSideMismatchCount(routes: bodyRepairedRoutes)
        <= context.maximumTerminalSideMismatches
    else {
      return nil
    }
    let bodyRepairedViolations = precomputedCrossedPortViolations(
      routes: bodyRepairedRoutes,
      nodeIndex: context.nodeIndex
    )
    guard bodyRepairedViolations.count < originalViolations.count else {
      return nil
    }
    return PolicyCanvasCrossedPortRepairCandidate(
      routes: bodyRepairedRoutes,
      violations: bodyRepairedViolations
    )
  }

  private func routesRepairingCrossedPorts(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    var currentRoutes = routes
    var currentViolations = precomputedCrossedPortViolations(
      routes: currentRoutes,
      nodeIndex: nodeIndex
    )
    for _ in 0..<6 {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let untangled = routesSwappingCrossedPortPairs(
        routes: currentRoutes,
        violations: currentViolations
      )
      let untangledViolations = precomputedCrossedPortViolations(
        routes: untangled,
        nodeIndex: nodeIndex
      )
      let repairContext = PolicyCanvasCrossedPortRepairContext(
        nodeIndex: nodeIndex,
        maximumBodyHits: precomputedBodyHits(routes: currentRoutes, nodeIndex: nodeIndex).count,
        maximumTerminalSideMismatches: precomputedTerminalSideMismatchCount(routes: currentRoutes),
        router: selectedRouter,
        algorithms: algorithms
      )
      guard
        let acceptedUntangled = crossedPortRepairCandidate(
          candidateRoutes: untangled,
          originalRoutes: currentRoutes,
          originalViolations: currentViolations,
          candidateViolations: untangledViolations,
          context: repairContext
        )
      else {
        break
      }
      currentRoutes = acceptedUntangled.routes
      currentViolations = acceptedUntangled.violations
    }
    for _ in 0..<3 {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let repaired = routesRepairingCrossedPorts(
        routes: currentRoutes,
        violations: currentViolations,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
      let repairedViolations = precomputedCrossedPortViolations(
        routes: repaired,
        nodeIndex: nodeIndex
      )
      guard repairedViolations.count < currentViolations.count else {
        break
      }
      currentRoutes = repaired
      currentViolations = repairedViolations
    }
    return currentRoutes
  }

  private func routesRepairingCrossedPorts(
    routes: [String: PolicyCanvasEdgeRoute],
    violations originalViolations: [PolicyCanvasCrossedPortsViolation],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> [String: PolicyCanvasEdgeRoute] {
    let markerLayout = portMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex,
      ordering: .farAxis
    )
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    let selectedRoutes = policyCanvasSelectedRoutes(
      phase: "precomputed-crossed-port-repair",
      portMarkerLayout: markerLayout,
      context: context
    )
    let crossedEdgeIDs = Set(originalViolations.flatMap { [$0.edgeA, $0.edgeB] })
    var repaired = routes
    for edge in edges where crossedEdgeIDs.contains(edge.id) {
      guard let route = selectedRoutes[edge.id] else {
        continue
      }
      repaired[edge.id] = route
    }
    let repairContext = PolicyCanvasCrossedPortRepairContext(
      nodeIndex: nodeIndex,
      maximumBodyHits: precomputedBodyHits(routes: routes, nodeIndex: nodeIndex).count,
      maximumTerminalSideMismatches: precomputedTerminalSideMismatchCount(routes: routes),
      router: selectedRouter,
      algorithms: algorithms
    )
    return crossedPortRepairCandidate(
      candidateRoutes: repaired,
      originalRoutes: routes,
      originalViolations: originalViolations,
      context: repairContext
    )?.routes ?? routes
  }

  private func precomputedBodyHitEdgeIDs(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Set<String> {
    Set(
      precomputedBodyHits(routes: routes, nodeIndex: nodeIndex)
        .map(\.edgeID)
    )
  }

  private func precomputedBodyHits(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    return policyCanvasMeasureBodyHits(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  private func precomputedBodyHits(
    edge: PolicyCanvasEdge,
    route: PolicyCanvasEdgeRoute,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasBodyHitViolation] {
    policyCanvasMeasureBodyHits(
      routedEdges: [PolicyCanvasRoutedEdge(edge: edge, route: route)],
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      groupTitleFrames: policyCanvasGroupTitleFramesByID(groups)
    )
  }

  private func precomputedTerminalSideMismatchCount(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> Int {
    var count = 0
    for edge in edges {
      guard let route = routes[edge.id] else {
        continue
      }
      if policyCanvasRouteSourceSide(route) != policyCanvasResolvedPortSide(for: edge.source) {
        count += 1
      }
      if policyCanvasRouteTargetSide(route) != policyCanvasResolvedPortSide(for: edge.target) {
        count += 1
      }
    }
    return count
  }

  private func precomputedCrossedPortViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasCrossedPortsViolation] {
    policyCanvasMeasureCrossedPorts(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame)
    )
  }

  private func precomputedRoutedEdges(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasRoutedEdge] {
    edges.compactMap { edge -> PolicyCanvasRoutedEdge? in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
  }

  private func routesSwappingCrossedPortPairs(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation]
  ) -> [String: PolicyCanvasEdgeRoute] {
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var repaired = routes
    let groupedViolations = Dictionary(grouping: violations) {
      PolicyCanvasCrossedPortGroupKey(nodeID: $0.nodeID, side: $0.side)
    }
    for (key, group) in groupedViolations.sorted(by: crossedPortGroupOrder) {
      repaired = routesSortingCrossedPortTerminalChannels(
        routes: repaired,
        violations: group,
        nodeID: key.nodeID,
        side: key.side,
        edgesByID: edgesByID
      )
    }
    return repaired
  }

  private func routesSortingCrossedPortTerminalChannels(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var terminalPoints: [String: CGPoint] = [:]
    for violation in violations {
      terminalPoints[violation.edgeA] = violation.pointA
      terminalPoints[violation.edgeB] = violation.pointB
    }
    let edgeIDs = terminalPoints.keys.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    var channelCoordinates: [String: CGFloat] = [:]
    var roles: [String: PolicyCanvasRouteEndpointRole] = [:]
    for edgeID in edgeIDs {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = routes[edgeID],
        let coordinate = terminalChannelCoordinate(route, role: role, side: side)
      else {
        return routes
      }
      roles[edgeID] = role
      channelCoordinates[edgeID] = coordinate
    }
    guard let groupRole = edgeIDs.first.flatMap({ roles[$0] }),
      edgeIDs.allSatisfy({ roles[$0] == groupRole })
    else {
      return routes
    }
    let sortedCoordinates =
      edgeIDs
      .compactMap { channelCoordinates[$0] }
      .sorted { left, right in
        let leftRank = terminalChannelOutwardRank(left, side: side)
        let rightRank = terminalChannelOutwardRank(right, side: side)
        return leftRank > rightRank
      }
    guard sortedCoordinates.count == edgeIDs.count else {
      return routes
    }
    let assignedCoordinates = terminalChannelCoordinatesResolvingCrowding(
      sortedCoordinates,
      side: side,
      role: groupRole
    )
    var repaired = routes
    for (edgeID, coordinate) in zip(edgeIDs, assignedCoordinates) {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = repaired[edgeID]
      else {
        continue
      }
      repaired[edgeID] = routeMovingTerminalChannel(
        route,
        role: role,
        side: side,
        coordinate: coordinate
      )
    }
    return repaired
  }

  private func terminalChannelCoordinatesResolvingCrowding(
    _ coordinates: [CGFloat],
    side: PolicyCanvasPortSide,
    role: PolicyCanvasRouteEndpointRole
  ) -> [CGFloat] {
    guard coordinates.count > 1 else {
      return coordinates
    }
    let minimumSpacing = PolicyCanvasLayout.routeChannelStep
    let hasCrowding = zip(coordinates, coordinates.dropFirst()).contains { left, right in
      abs(right - left) < minimumSpacing - 0.001
    }
    guard hasCrowding else {
      return coordinates
    }
    let base: CGFloat
    switch side {
    case .leading, .top:
      base = coordinates.max() ?? 0
    case .trailing, .bottom:
      base = coordinates.min() ?? 0
    }
    return coordinates.indices.map { index in
      terminalFanChannelCoordinate(
        base: base,
        index: index,
        count: coordinates.count,
        side: side,
        role: role
      )
    }
  }

  private func routesRebuildingCrossedPortTerminalFan(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let group = crossedPortTerminalFanGroup(
        routes: routes,
        violations: violations,
        nodeID: nodeID,
        side: side,
        edgesByID: edgesByID
      )
    else {
      return routes
    }
    var repaired = routes
    for (index, edgeID) in group.edgeIDs.enumerated() {
      guard
        let point = group.terminalPoints[edgeID],
        let route = routes[edgeID]
      else {
        continue
      }
      let lead = policyCanvasPortLeadPoint(point, side: side)
      let coordinate = terminalFanChannelCoordinate(
        base: terminalChannelCoordinate(lead, side: side),
        index: index,
        count: group.edgeIDs.count,
        side: side,
        role: group.role
      )
      repaired[edgeID] = routeRebuildingTerminalFan(
        route,
        side: side,
        channelCoordinate: coordinate
      )
    }
    return repaired
  }

  private func routesOrderingCrossedPortTerminalFanByFarAxis(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let group = crossedPortTerminalFanGroup(
        routes: routes,
        violations: violations,
        nodeID: nodeID,
        side: side,
        edgesByID: edgesByID
      )
    else {
      return routes
    }
    let slotPoints = group.edgeIDs.compactMap { group.terminalPoints[$0] }
    guard slotPoints.count == group.edgeIDs.count else {
      return routes
    }
    let edgeIDsByFarAxis = group.edgeIDs.sorted { left, right in
      guard let leftRoute = routes[left], let rightRoute = routes[right] else {
        return left < right
      }
      let leftAxis = terminalFanFarAxis(leftRoute, role: group.role, side: side)
      let rightAxis = terminalFanFarAxis(rightRoute, role: group.role, side: side)
      if abs(leftAxis - rightAxis) > 0.001 {
        return leftAxis < rightAxis
      }
      let leftPoint = group.terminalPoints[left] ?? .zero
      let rightPoint = group.terminalPoints[right] ?? .zero
      let leftTerminalAxis = crossedPortAxis(leftPoint, side: side)
      let rightTerminalAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftTerminalAxis - rightTerminalAxis) > 0.001
        ? leftTerminalAxis < rightTerminalAxis : left < right
    }
    var repaired = routes
    for (index, edgeID) in edgeIDsByFarAxis.enumerated() {
      guard let route = repaired[edgeID] else {
        continue
      }
      let point = slotPoints[index]
      let moved = routeMovingTerminal(
        route,
        role: group.role,
        side: side,
        point: point
      )
      let lead = policyCanvasPortLeadPoint(point, side: side)
      let coordinate = terminalFanChannelCoordinate(
        base: terminalChannelCoordinate(lead, side: side),
        index: index,
        count: edgeIDsByFarAxis.count,
        side: side,
        role: group.role
      )
      repaired[edgeID] = routeRebuildingTerminalFan(
        moved,
        side: side,
        channelCoordinate: coordinate
      )
    }
    return repaired
  }

  private func crossedPortTerminalFanGroup(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> PolicyCanvasCrossedPortTerminalFanGroup? {
    let violationEdgeIDs = Set(violations.flatMap { [$0.edgeA, $0.edgeB] })
    var terminalPoints: [String: CGPoint] = [:]
    var roles: [String: PolicyCanvasRouteEndpointRole] = [:]
    for edgeID in violationEdgeIDs {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = routes[edgeID],
        let point = terminalFanTerminalPoint(route, role: role)
      else {
        return nil
      }
      roles[edgeID] = role
      terminalPoints[edgeID] = point
    }
    let edgeIDs = violationEdgeIDs.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    guard let groupRole = edgeIDs.first.flatMap({ roles[$0] }),
      edgeIDs.allSatisfy({ roles[$0] == groupRole })
    else {
      return nil
    }
    return PolicyCanvasCrossedPortTerminalFanGroup(
      edgeIDs: edgeIDs,
      terminalPoints: terminalPoints,
      role: groupRole
    )
  }

  private func routesSwappingCrossedPortPairTerminalChannels(
    routes: [String: PolicyCanvasEdgeRoute],
    violation: PolicyCanvasCrossedPortsViolation,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    guard
      let edgeA = edgesByID[violation.edgeA],
      let edgeB = edgesByID[violation.edgeB],
      let roleA = crossedPortRole(edge: edgeA, nodeID: violation.nodeID),
      let roleB = crossedPortRole(edge: edgeB, nodeID: violation.nodeID),
      roleA == roleB,
      let routeA = routes[violation.edgeA],
      let routeB = routes[violation.edgeB],
      let channelA = terminalChannelCoordinate(
        routeA,
        role: roleA,
        side: violation.side
      ),
      let channelB = terminalChannelCoordinate(
        routeB,
        role: roleB,
        side: violation.side
      ),
      abs(channelA - channelB) > 0.5
    else {
      return routes
    }
    var repaired = routes
    repaired[violation.edgeA] = routeMovingTerminalChannel(
      routeA,
      role: roleA,
      side: violation.side,
      coordinate: channelB
    )
    repaired[violation.edgeB] = routeMovingTerminalChannel(
      routeB,
      role: roleB,
      side: violation.side,
      coordinate: channelA
    )
    return repaired
  }

  private func routesSortingCrossedPortGroup(
    routes: [String: PolicyCanvasEdgeRoute],
    violations: [PolicyCanvasCrossedPortsViolation],
    nodeID: String,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var terminalPoints: [String: CGPoint] = [:]
    var successors: [String: Set<String>] = [:]
    var predecessors: [String: Set<String>] = [:]
    for violation in violations {
      terminalPoints[violation.edgeA] = violation.pointA
      terminalPoints[violation.edgeB] = violation.pointB
      successors[violation.edgeB, default: []].insert(violation.edgeA)
      predecessors[violation.edgeA, default: []].insert(violation.edgeB)
    }
    let edgeIDs = terminalPoints.keys.sorted { left, right in
      let leftPoint = terminalPoints[left] ?? .zero
      let rightPoint = terminalPoints[right] ?? .zero
      let leftAxis = crossedPortAxis(leftPoint, side: side)
      let rightAxis = crossedPortAxis(rightPoint, side: side)
      return abs(leftAxis - rightAxis) > 0.001 ? leftAxis < rightAxis : left < right
    }
    let sortedEdgeIDs =
      topologicallySortedCrossedPortEdges(
        edgeIDs: edgeIDs,
        successors: successors,
        predecessors: predecessors
      )
      ?? fallbackSortedCrossedPortEdges(
        edgeIDs: edgeIDs,
        successors: successors,
        predecessors: predecessors
      )
    let sortedPoints = edgeIDs.compactMap { terminalPoints[$0] }
    guard sortedEdgeIDs.count == sortedPoints.count else {
      return routes
    }
    var repaired = routes
    for (edgeID, point) in zip(sortedEdgeIDs, sortedPoints) {
      guard
        let edge = edgesByID[edgeID],
        let role = crossedPortRole(edge: edge, nodeID: nodeID),
        let route = repaired[edgeID]
      else {
        continue
      }
      repaired[edgeID] = routeMovingTerminal(
        route,
        role: role,
        side: side,
        point: point
      )
    }
    return repaired
  }

  private func topologicallySortedCrossedPortEdges(
    edgeIDs: [String],
    successors: [String: Set<String>],
    predecessors: [String: Set<String>]
  ) -> [String]? {
    let originalOrder = Dictionary(uniqueKeysWithValues: edgeIDs.enumerated().map { ($1, $0) })
    var incoming = Dictionary(
      uniqueKeysWithValues: edgeIDs.map { ($0, predecessors[$0, default: []].count) }
    )
    var ready = edgeIDs.filter { incoming[$0, default: 0] == 0 }
    var sorted: [String] = []
    while !ready.isEmpty {
      ready.sort { originalOrder[$0, default: 0] < originalOrder[$1, default: 0] }
      let edgeID = ready.removeFirst()
      sorted.append(edgeID)
      for next in successors[edgeID, default: []]
        .sorted(by: { originalOrder[$0, default: 0] < originalOrder[$1, default: 0] })
      {
        incoming[next, default: 0] -= 1
        if incoming[next, default: 0] == 0 {
          ready.append(next)
        }
      }
    }
    return sorted.count == edgeIDs.count ? sorted : nil
  }

  private func fallbackSortedCrossedPortEdges(
    edgeIDs: [String],
    successors: [String: Set<String>],
    predecessors: [String: Set<String>]
  ) -> [String] {
    let originalOrder = Dictionary(uniqueKeysWithValues: edgeIDs.enumerated().map { ($1, $0) })
    return edgeIDs.sorted { left, right in
      let leftScore = predecessors[left, default: []].count - successors[left, default: []].count
      let rightScore =
        predecessors[right, default: []].count - successors[right, default: []].count
      return leftScore == rightScore
        ? originalOrder[left, default: 0] < originalOrder[right, default: 0]
        : leftScore < rightScore
    }
  }

  private func crossedPortAxis(
    _ point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      point.y
    case .top, .bottom:
      point.x
    }
  }

  private func crossedPortGroupOrder(
    lhs: (
      key: PolicyCanvasCrossedPortGroupKey,
      value: [PolicyCanvasCrossedPortsViolation]
    ),
    rhs: (
      key: PolicyCanvasCrossedPortGroupKey,
      value: [PolicyCanvasCrossedPortsViolation]
    )
  ) -> Bool {
    if lhs.key.nodeID != rhs.key.nodeID {
      return lhs.key.nodeID < rhs.key.nodeID
    }
    return lhs.key.side.rawValue < rhs.key.side.rawValue
  }

  private struct PolicyCanvasCrossedPortGroupKey: Hashable {
    let nodeID: String
    let side: PolicyCanvasPortSide
  }

  private struct PolicyCanvasCrossedPortRepairCandidate {
    let routes: [String: PolicyCanvasEdgeRoute]
    let violations: [PolicyCanvasCrossedPortsViolation]
  }

  private struct PolicyCanvasCrossedPortRepairContext {
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let maximumBodyHits: Int
    let maximumTerminalSideMismatches: Int
    let router: any PolicyCanvasEdgeRouter
    let algorithms: PolicyCanvasRoutingAlgorithmSet
  }

  private struct PolicyCanvasTerminalRepairContext {
    let portMarkerLayout: PolicyCanvasPortMarkerLayout
    let nodeIndex: [String: PolicyCanvasRouteNode]
  }

  private struct PolicyCanvasTerminalSnapState {
    var score: Int
    var bodyHits: Int
  }

  private struct PolicyCanvasTerminalMismatchInput {
    let edgeID: String
    let role: PolicyCanvasRouteEndpointRole
    let endpoint: PolicyCanvasPortEndpoint
    let routePoint: CGPoint?
    let leadPoint: CGPoint?
    let routeSide: PolicyCanvasPortSide?
  }

  private struct PolicyCanvasCrossedPortTerminalFanGroup {
    let edgeIDs: [String]
    let terminalPoints: [String: CGPoint]
    let role: PolicyCanvasRouteEndpointRole
  }

  private func crossedPortRole(
    edge: PolicyCanvasEdge,
    nodeID: String
  ) -> PolicyCanvasRouteEndpointRole? {
    if edge.source.nodeID == nodeID {
      return .source
    }
    if edge.target.nodeID == nodeID {
      return .target
    }
    return nil
  }

  private func routeMovingTerminal(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    point: CGPoint
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 2 else {
      return route
    }
    let lead = policyCanvasPortLeadPoint(point, side: side)
    var points: [CGPoint] = []
    switch role {
    case .source:
      let oldLead = route.points[1]
      var tracksSourceRun = true
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      for index in 2..<route.points.count {
        var oldPoint = route.points[index]
        if tracksSourceRun, index < route.points.count - 2,
          terminalRunPoint(oldPoint, sharesAxisWith: oldLead, side: side)
        {
          oldPoint = pointReplacingTerminalAxis(oldPoint, with: lead, side: side)
        } else if index < route.points.count - 2 {
          tracksSourceRun = false
        }
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
    case .target:
      let oldLead = route.points[route.points.count - 2]
      let adjustedPoints = pointsAdjustingTargetTerminalRun(
        route.points,
        oldLead: oldLead,
        newLead: lead,
        side: side
      )
      for oldPoint in adjustedPoints.dropLast(2) {
        policyCanvasAppendOrthogonalBridge(oldPoint, to: &points)
      }
      policyCanvasAppendOrthogonalBridge(lead, to: &points)
      policyCanvasAppendOrthogonalBridge(point, to: &points)
    }
    let compressed = policyCanvasCompressPreservingTerminalStubs(points)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func pointsAdjustingTargetTerminalRun(
    _ points: [CGPoint],
    oldLead: CGPoint,
    newLead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    guard points.count > 4 else {
      return points
    }
    var adjusted = points
    var index = points.count - 3
    while index >= 2,
      terminalRunPoint(adjusted[index], sharesAxisWith: oldLead, side: side)
    {
      adjusted[index] = pointReplacingTerminalAxis(adjusted[index], with: newLead, side: side)
      index -= 1
    }
    return adjusted
  }

  private func terminalRunPoint(
    _ point: CGPoint,
    sharesAxisWith lead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> Bool {
    switch side {
    case .leading, .trailing:
      return abs(point.y - lead.y) <= 0.001
    case .top, .bottom:
      return abs(point.x - lead.x) <= 0.001
    }
  }

  private func pointReplacingTerminalAxis(
    _ point: CGPoint,
    with lead: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGPoint {
    switch side {
    case .leading, .trailing:
      return CGPoint(x: point.x, y: lead.y)
    case .top, .bottom:
      return CGPoint(x: lead.x, y: point.y)
    }
  }

  private func terminalChannelCoordinate(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> CGFloat? {
    guard
      let indexes = terminalChannelSegmentIndexes(route.points, role: role, side: side)
    else {
      return nil
    }
    return terminalChannelCoordinate(route.points[indexes.lower], side: side)
  }

  private func terminalChannelSegmentIndexes(
    _ points: [CGPoint],
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> (lower: Int, upper: Int)? {
    guard points.count >= 3 else {
      return nil
    }
    switch role {
    case .source:
      for index in 2..<points.count
      where terminalChannelSegment(points[index - 1], points[index], side: side) {
        return (index - 1, index)
      }
    case .target:
      var index = points.count - 2
      while index >= 1 {
        if terminalChannelSegment(points[index - 1], points[index], side: side) {
          return (index - 1, index)
        }
        index -= 1
      }
    }
    return nil
  }

  private func terminalChannelSegment(
    _ start: CGPoint,
    _ end: CGPoint,
    side: PolicyCanvasPortSide
  ) -> Bool {
    switch side {
    case .leading, .trailing:
      return abs(start.x - end.x) <= 0.5 && abs(start.y - end.y) > 0.5
    case .top, .bottom:
      return abs(start.y - end.y) <= 0.5 && abs(start.x - end.x) > 0.5
    }
  }

  private func terminalChannelCoordinate(
    _ point: CGPoint,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .trailing:
      return point.x
    case .top, .bottom:
      return point.y
    }
  }

  private func terminalChannelOutwardRank(
    _ coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    switch side {
    case .leading, .top:
      return -coordinate
    case .trailing, .bottom:
      return coordinate
    }
  }

  private func routeMovingTerminalChannel(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide,
    coordinate: CGFloat
  ) -> PolicyCanvasEdgeRoute {
    guard
      let indexes = terminalChannelSegmentIndexes(route.points, role: role, side: side)
    else {
      return route
    }
    let points = route.points
    let oldCoordinate = terminalChannelCoordinate(points[indexes.lower], side: side)
    let rebuilt =
      switch role {
      case .source:
        pointsMovingSourceTerminalChannel(
          points,
          indexes: indexes,
          oldCoordinate: oldCoordinate,
          coordinate: coordinate,
          side: side
        )
      case .target:
        pointsMovingTargetTerminalChannel(
          points,
          indexes: indexes,
          oldCoordinate: oldCoordinate,
          coordinate: coordinate,
          side: side
        )
      }
    let compressed = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func pointsMovingSourceTerminalChannel(
    _ points: [CGPoint],
    indexes: (lower: Int, upper: Int),
    oldCoordinate: CGFloat,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    var rebuilt: [CGPoint] = []
    var index = indexes.lower
    policyCanvasAppendOrthogonalBridge(points[0], to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(points[1], to: &rebuilt)
    while index < points.count - 1,
      terminalChannelPoint(points[index], coordinate: oldCoordinate, side: side)
    {
      let adjusted = pointReplacingTerminalChannel(points[index], with: coordinate, side: side)
      policyCanvasAppendOrthogonalBridge(adjusted, to: &rebuilt)
      index += 1
    }
    while index < points.count {
      policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      index += 1
    }
    return rebuilt
  }

  private func pointsMovingTargetTerminalChannel(
    _ points: [CGPoint],
    indexes: (lower: Int, upper: Int),
    oldCoordinate: CGFloat,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> [CGPoint] {
    var runStart = indexes.lower
    while runStart > 1,
      terminalChannelPoint(points[runStart - 1], coordinate: oldCoordinate, side: side)
    {
      runStart -= 1
    }
    var runEnd = indexes.upper
    while runEnd < points.count - 3,
      terminalChannelPoint(points[runEnd + 1], coordinate: oldCoordinate, side: side)
    {
      runEnd += 1
    }
    let adjustedEnd = min(runEnd, points.count - 3)
    var rebuilt: [CGPoint] = []
    var index = 0
    while index < runStart {
      policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      index += 1
    }
    while index <= adjustedEnd {
      let adjusted = pointReplacingTerminalChannel(points[index], with: coordinate, side: side)
      policyCanvasAppendOrthogonalBridge(adjusted, to: &rebuilt)
      index += 1
    }
    var exitsMovedChannel =
      rebuilt.last.map {
        terminalChannelPoint($0, coordinate: coordinate, side: side)
      } ?? false
    while index < points.count {
      if exitsMovedChannel {
        policyCanvasAppendTerminalChannelExitBridge(
          points[index],
          channelCoordinate: coordinate,
          side: side,
          to: &rebuilt
        )
        exitsMovedChannel = false
      } else {
        policyCanvasAppendOrthogonalBridge(points[index], to: &rebuilt)
      }
      index += 1
    }
    return rebuilt
  }

  private func terminalChannelPoint(
    _ point: CGPoint,
    coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> Bool {
    abs(terminalChannelCoordinate(point, side: side) - coordinate) <= 0.5
  }

  private func pointReplacingTerminalChannel(
    _ point: CGPoint,
    with coordinate: CGFloat,
    side: PolicyCanvasPortSide
  ) -> CGPoint {
    switch side {
    case .leading, .trailing:
      return CGPoint(x: coordinate, y: point.y)
    case .top, .bottom:
      return CGPoint(x: point.x, y: coordinate)
    }
  }

  private func terminalFanChannelCoordinate(
    base: CGFloat,
    index: Int,
    count: Int,
    side: PolicyCanvasPortSide,
    role: PolicyCanvasRouteEndpointRole
  ) -> CGFloat {
    let ordinal: CGFloat =
      switch role {
      case .source:
        CGFloat(index)
      case .target:
        CGFloat(max(0, count - index - 1))
      }
    return base
      + (terminalFanOutwardDirection(side) * ordinal * PolicyCanvasLayout.routeChannelStep)
  }

  private func terminalFanOutwardDirection(_ side: PolicyCanvasPortSide) -> CGFloat {
    switch side {
    case .leading, .top:
      -1
    case .trailing, .bottom:
      1
    }
  }

  private func terminalFanTerminalPoint(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole
  ) -> CGPoint? {
    switch role {
    case .source:
      route.points.first
    case .target:
      route.points.last
    }
  }

  private func terminalFanFarAxis(
    _ route: PolicyCanvasEdgeRoute,
    role: PolicyCanvasRouteEndpointRole,
    side: PolicyCanvasPortSide
  ) -> CGFloat {
    let point: CGPoint?
    switch role {
    case .source:
      point = route.points.last
    case .target:
      point = route.points.first
    }
    return point.map { crossedPortAxis($0, side: side) } ?? 0
  }

  private func routeRebuildingTerminalFan(
    _ route: PolicyCanvasEdgeRoute,
    side: PolicyCanvasPortSide,
    channelCoordinate: CGFloat
  ) -> PolicyCanvasEdgeRoute {
    guard route.points.count >= 4,
      let sourcePoint = route.points.first,
      let targetPoint = route.points.last
    else {
      return route
    }
    let sourceLead = route.points[1]
    let targetLead = route.points[route.points.count - 2]
    var rebuilt: [CGPoint] = []
    policyCanvasAppendOrthogonalBridge(sourcePoint, to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(sourceLead, to: &rebuilt)
    switch side {
    case .leading, .trailing:
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: channelCoordinate, y: sourceLead.y),
        to: &rebuilt
      )
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: channelCoordinate, y: targetLead.y),
        to: &rebuilt
      )
    case .top, .bottom:
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: sourceLead.x, y: channelCoordinate),
        to: &rebuilt
      )
      policyCanvasAppendOrthogonalBridge(
        CGPoint(x: targetLead.x, y: channelCoordinate),
        to: &rebuilt
      )
    }
    policyCanvasAppendOrthogonalBridge(targetLead, to: &rebuilt)
    policyCanvasAppendOrthogonalBridge(targetPoint, to: &rebuilt)
    let compressed = policyCanvasCompressPreservingTerminalStubs(rebuilt)
    return PolicyCanvasEdgeRoute(
      points: compressed,
      labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
    )
  }

  private func policyCanvasAppendTerminalChannelExitBridge(
    _ point: CGPoint,
    channelCoordinate: CGFloat,
    side: PolicyCanvasPortSide,
    to points: inout [CGPoint]
  ) {
    guard let last = points.last,
      abs(last.x - point.x) > 0.001,
      abs(last.y - point.y) > 0.001
    else {
      policyCanvasAppendOrthogonalBridge(point, to: &points)
      return
    }
    let channelExit: CGPoint =
      switch side {
      case .leading, .trailing:
        CGPoint(x: channelCoordinate, y: point.y)
      case .top, .bottom:
        CGPoint(x: point.x, y: channelCoordinate)
      }
    policyCanvasAppendOrthogonalBridge(channelExit, to: &points)
    policyCanvasAppendOrthogonalBridge(point, to: &points)
  }

  private func routesReroutingBalancedPortMarkers(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let portMarkerLayout = portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    return policyCanvasReroutedState(portMarkerLayout: portMarkerLayout, context: context)
  }

  private func routesBalancingPrecomputedPortMarkers(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let precomputedLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: routes,
      nodeIndex: nodeIndex
    )
    guard precomputedRoutesHavePortSpacingViolations(routes: routes, nodeIndex: nodeIndex) else {
      return PolicyCanvasRouteComputationState(routes: routes, portMarkerLayout: precomputedLayout)
    }
    let balancedLayout = portMarkerLayout(routes: routes, nodeIndex: nodeIndex)
    let snappedRoutes = routesSnappingTerminals(
      routes: routes,
      portMarkerLayout: balancedLayout,
      nodeIndex: nodeIndex
    )
    guard precomputedBodyHits(routes: snappedRoutes, nodeIndex: nodeIndex).isEmpty else {
      return routesReroutingBalancedPortMarkers(
        routes: routes,
        nodeIndex: nodeIndex,
        router: selectedRouter,
        algorithms: algorithms
      )
    }
    return PolicyCanvasRouteComputationState(
      routes: snappedRoutes, portMarkerLayout: balancedLayout)
  }

  private func precomputedRoutesHavePortSpacingViolations(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Bool {
    !policyCanvasMeasurePortSpacing(
      routedEdges: precomputedRoutedEdges(routes: routes),
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      thresholds: .default
    ).isEmpty
  }

  private func routesSnappingTerminals(
    routes: [String: PolicyCanvasEdgeRoute],
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [String: PolicyCanvasEdgeRoute] {
    var snapped = routes
    for edge in edges {
      guard var route = snapped[edge.id] else {
        continue
      }
      if let sourcePoint = portMarkerPoint(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        portMarkerLayout: portMarkerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeMovingTerminal(
          route,
          role: .source,
          side: sourcePoint.side,
          point: sourcePoint.point
        )
      }
      if let targetPoint = portMarkerPoint(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        portMarkerLayout: portMarkerLayout,
        nodeIndex: nodeIndex
      ) {
        route = routeMovingTerminal(
          route,
          role: .target,
          side: targetPoint.side,
          point: targetPoint.point
        )
      }
      snapped[edge.id] = route
    }
    return snapped
  }

  private func portMarkerPoint(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> (point: CGPoint, side: PolicyCanvasPortSide)? {
    guard
      let terminal = portMarkerLayout.terminal(edgeID: edgeID, role: role),
      let base = portAnchor(for: endpoint, side: terminal.side, nodeIndex: nodeIndex)
    else {
      return nil
    }
    return (
      policyCanvasShiftedRouteAnchor(base, side: terminal.side, terminal: terminal),
      terminal.side
    )
  }

  private func precomputedRouteTerminalPortMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    var endpoints: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint] = [:]
    terminals.reserveCapacity(routes.count * 2)
    endpoints.reserveCapacity(routes.count * 2)
    for edge in edges {
      guard let route = routes[edge.id] else {
        continue
      }
      precomputedRouteTerminal(
        edgeID: edge.id,
        role: .source,
        endpoint: edge.source,
        point: route.points.first,
        side: policyCanvasRouteSourceSide(route),
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
      precomputedRouteTerminal(
        edgeID: edge.id,
        role: .target,
        endpoint: edge.target,
        point: route.points.last,
        side: policyCanvasRouteTargetSide(route),
        nodeIndex: nodeIndex,
        terminals: &terminals,
        endpoints: &endpoints
      )
    }
    return PolicyCanvasPortMarkerLayout(terminalsByKey: terminals, endpointsByKey: endpoints)
  }

  private func precomputedRouteTerminal(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole,
    endpoint: PolicyCanvasPortEndpoint,
    point: CGPoint?,
    side: PolicyCanvasPortSide?,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpoints: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    let side = policyCanvasResolvedRoutablePortSide(for: endpoint, preferredSide: side)
    guard
      let point,
      let base = portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex)
    else {
      return
    }
    let key = PolicyCanvasRouteTerminalKey(edgeID: edgeID, role: role)
    terminals[key] = PolicyCanvasPortTerminal(
      side: side,
      axisOffset: precomputedRouteTerminalAxisOffset(from: base, to: point, side: side)
    )
    endpoints[key] = endpoint
  }

  private func precomputedRouteTerminalAxisOffset(
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

  func portVisibility(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortVisibilityMap {
    policyCanvasPortVisibility(edges: edges, routes: routes) { endpoint in
      routeAnchorCandidates(for: endpoint, nodeIndex: nodeIndex)
    }
  }

  private func routingObstacles() -> [CGRect] {
    policyCanvasCanonicalObstacles(nodes.map(\.frame) + policyCanvasGroupTitleFrames(groups))
  }

  func displayedRoutePassContext(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasDisplayedRoutePassContext {
    let obstacles = routingObstacles()
    let portAnchors = portAnchors(nodeIndex: nodeIndex)
    let orderedEdges = policyCanvasRouteBuildOrder(edges: edges, portAnchors: portAnchors)
    let terminalSlots = routeEndpointSlots(edges: orderedEdges, nodeIndex: nodeIndex)
    let familyPreferences = policyCanvasRouteFamilyPreferences(
      edges: edges,
      nodeFramesByID: nodeIndex.mapValues(\.frame),
      nodeGroupIDsByID: nodeIndex.mapValues(\.groupID)
    )
    let edgeLanes = policyCanvasSharedTargetRouteLaneAssignments(
      edges: edges,
      bucket: { edgeRouteBucket($0, nodeIndex: nodeIndex) },
      sortKey: { edgeRouteSortKey($0, nodeIndex: nodeIndex) }
    )
    let sourceFanoutLanes = policyCanvasLaneAssignments(
      edges: edges,
      bucket: edgeSourceFanoutBucket,
      sortKey: { edgeSourceFanoutSortKey($0, nodeIndex: nodeIndex) }
    )
    let targetFanoutLanes = policyCanvasTargetFanoutLaneAssignments(
      edges: edges,
      familyPreferences: familyPreferences,
      bucket: edgeTargetFanoutBucket,
      sortKey: { edgeTargetFanoutSortKey($0, nodeIndex: nodeIndex) }
    )
    return PolicyCanvasDisplayedRoutePassContext(
      nodeIndex: nodeIndex,
      obstacles: obstacles,
      portAnchors: portAnchors,
      orderedEdges: orderedEdges,
      terminalSlots: terminalSlots,
      familyPreferences: familyPreferences,
      edgeLanes: edgeLanes,
      sourceFanoutLanes: sourceFanoutLanes,
      targetFanoutLanes: targetFanoutLanes
    )
  }

  func portAnchors(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> [PolicyCanvasPortEndpoint: CGPoint] {
    var anchors: [PolicyCanvasPortEndpoint: CGPoint] = [:]
    anchors.reserveCapacity(edges.count * 2)
    for edge in edges {
      if let point = portAnchor(for: edge.source, nodeIndex: nodeIndex) {
        anchors[edge.source] = point
      }
      if let point = portAnchor(for: edge.target, nodeIndex: nodeIndex) {
        anchors[edge.target] = point
      }
    }
    return anchors
  }

  private func routeAnchorCandidates(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminalSlot: PolicyCanvasRouteEndpointSlot = .single,
    terminal: PolicyCanvasPortTerminal? = nil
  ) -> [PolicyCanvasRouteAnchorCandidate] {
    let sides = terminal.map { [$0.side] } ?? policyCanvasRoutablePortSides(for: endpoint.kind)
    return sides.compactMap { side in
      routeAnchorCandidate(
        for: endpoint,
        side: side,
        nodeIndex: nodeIndex,
        terminalSlot: terminalSlot,
        terminal: terminal
      )
    }
  }

  private struct PolicyCanvasRouteComputationState {
    let routes: [String: PolicyCanvasEdgeRoute]
    let portMarkerLayout: PolicyCanvasPortMarkerLayout
  }

  private struct PolicyCanvasRouteStateContext {
    let prepared: PolicyCanvasPreparedRouteInput
    let nodeIndex: [String: PolicyCanvasRouteNode]
    let passContext: PolicyCanvasDisplayedRoutePassContext
    let router: any PolicyCanvasEdgeRouter
    let algorithms: PolicyCanvasRoutingAlgorithmSet
  }

  private func policyCanvasConvergedRouteState(
    prepared: PolicyCanvasPreparedRouteInput,
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet
  ) -> PolicyCanvasRouteComputationState {
    let context = PolicyCanvasRouteStateContext(
      prepared: prepared,
      nodeIndex: nodeIndex,
      passContext: prepared.displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )
    if let seedLayout = algorithms.portMarkerPlacement.seedMarkers(
      input: PolicyCanvasPortMarkerSeedInput(prepared: prepared, nodeIndex: nodeIndex)
    ) {
      let state = policyCanvasNextRouteState(
        current: PolicyCanvasRouteComputationState(routes: [:], portMarkerLayout: seedLayout),
        context: context
      )
      if prepared.edges.count > policyCanvasSinglePassSeededRoutingThreshold {
        return PolicyCanvasRouteComputationState(
          routes: state.routes,
          portMarkerLayout: seedLayout
        )
      }
      if state.portMarkerLayout == seedLayout {
        return state
      }
      let seenLayouts = [seedLayout, state.portMarkerLayout]
      return policyCanvasConvergedRouteState(
        state: state,
        seenLayouts: seenLayouts,
        context: context
      )
    }
    let state = policyCanvasInitialRouteState(context: context)
    return policyCanvasConvergedRouteState(
      state: state,
      seenLayouts: [state.portMarkerLayout],
      context: context
    )
  }

  private func policyCanvasConvergedRouteState(
    state initialState: PolicyCanvasRouteComputationState,
    seenLayouts initialSeenLayouts: [PolicyCanvasPortMarkerLayout],
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    var state = initialState
    var seenLayouts = initialSeenLayouts
    for _ in 0..<3 {
      let nextState = policyCanvasNextRouteState(
        current: state,
        context: context
      )
      if nextState.portMarkerLayout == state.portMarkerLayout {
        return nextState
      }
      if seenLayouts.contains(nextState.portMarkerLayout) {
        return policyCanvasReroutedState(
          portMarkerLayout: nextState.portMarkerLayout,
          context: context
        )
      }
      seenLayouts.append(nextState.portMarkerLayout)
      state = nextState
    }
    return policyCanvasReroutedState(
      portMarkerLayout: state.portMarkerLayout,
      context: context
    )
  }

  private func policyCanvasInitialRouteState(
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    let initialRoutes = policyCanvasSelectedRoutes(
      phase: "initial",
      portMarkerLayout: nil,
      context: context
    )
    return PolicyCanvasRouteComputationState(
      routes: initialRoutes,
      portMarkerLayout: context.algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: context.prepared,
          routes: initialRoutes,
          nodeIndex: context.nodeIndex
        )
      )
    )
  }

  private func policyCanvasNextRouteState(
    current: PolicyCanvasRouteComputationState,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    let routes = policyCanvasSelectedRoutes(
      phase: "next",
      portMarkerLayout: current.portMarkerLayout,
      context: context
    )
    return PolicyCanvasRouteComputationState(
      routes: routes,
      portMarkerLayout: context.algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: context.prepared,
          routes: routes,
          nodeIndex: context.nodeIndex
        )
      )
    )
  }

  private func policyCanvasReroutedState(
    portMarkerLayout: PolicyCanvasPortMarkerLayout,
    context: PolicyCanvasRouteStateContext
  ) -> PolicyCanvasRouteComputationState {
    PolicyCanvasRouteComputationState(
      routes: policyCanvasSelectedRoutes(
        phase: "reroute",
        portMarkerLayout: portMarkerLayout,
        context: context
      ),
      portMarkerLayout: portMarkerLayout
    )
  }

  private func policyCanvasSelectedRoutes(
    phase: String,
    portMarkerLayout: PolicyCanvasPortMarkerLayout?,
    context: PolicyCanvasRouteStateContext
  ) -> [String: PolicyCanvasEdgeRoute] {
    let signpostID = policyCanvasRouteComputationSignposter.makeSignpostID()
    let markerState = portMarkerLayout == nil ? "none" : "layout"
    let interval = policyCanvasRouteComputationSignposter.beginInterval(
      "policy_canvas.routes.phase.route_selection",
      id: signpostID,
      "phase=\(phase, privacy: .public) markers=\(markerState, privacy: .public)"
    )
    let routes = context.algorithms.routeSelection.selectRoutes(
      input: PolicyCanvasRouteSelectionInput(
        prepared: context.prepared,
        router: context.router,
        portMarkerLayout: portMarkerLayout,
        passContext: context.passContext
      )
    )
    policyCanvasRouteComputationSignposter.endInterval(
      "policy_canvas.routes.phase.route_selection",
      interval,
      "phase=\(phase, privacy: .public) routes=\(routes.count, privacy: .public)"
    )
    return routes
  }

  func routeAnchorCandidate(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminalSlot: PolicyCanvasRouteEndpointSlot,
    terminal: PolicyCanvasPortTerminal? = nil
  ) -> PolicyCanvasRouteAnchorCandidate? {
    guard
      let point = portAnchor(for: endpoint, side: side, nodeIndex: nodeIndex),
      let node = nodeIndex[endpoint.nodeID]
    else {
      return nil
    }
    if let terminal {
      return (
        point: policyCanvasShiftedRouteAnchor(point, side: side, terminal: terminal), side: side
      )
    }
    let spacing = max(
      portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      policyCanvasMinimumPortMarkerSpacing()
    )
    return (
      point: policyCanvasShiftedRouteAnchor(
        point,
        side: side,
        frame: node.frame,
        spacing: spacing,
        terminalSlot: terminalSlot
      ),
      side: side
    )
  }

  func portAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    portAnchor(
      for: endpoint,
      side: policyCanvasResolvedPortSide(for: endpoint),
      nodeIndex: nodeIndex
    )
  }

  func portAnchor(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    guard let node = nodeIndex[endpoint.nodeID] else {
      return nil
    }
    let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
    guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
      return nil
    }
    return portAnchor(for: node, side: side, index: index, count: ports.count)
  }

  func portAnchor(
    for node: PolicyCanvasRouteNode,
    side: PolicyCanvasPortSide,
    index: Int,
    count: Int
  ) -> CGPoint {
    switch side {
    case .leading:
      CGPoint(
        x: node.position.x,
        y: node.position.y
          + PolicyCanvasLayout.portY(
            index: index,
            count: count,
            nodeHeight: node.size.height
          )
      )
    case .trailing:
      CGPoint(
        x: node.position.x + node.size.width,
        y: node.position.y
          + PolicyCanvasLayout.portY(
            index: index,
            count: count,
            nodeHeight: node.size.height
          )
      )
    case .top:
      CGPoint(
        x: node.position.x
          + PolicyCanvasLayout.portX(
            index: index,
            count: count,
            nodeWidth: node.size.width
          ),
        y: node.position.y)
    case .bottom:
      CGPoint(
        x: node.position.x
          + PolicyCanvasLayout.portX(
            index: index,
            count: count,
            nodeWidth: node.size.width
          ),
        y: node.position.y + node.size.height
      )
    }
  }
}

func policyCanvasRoutesPreservingRouteTerminals(
  original: [String: PolicyCanvasEdgeRoute],
  processed: [String: PolicyCanvasEdgeRoute]
) -> [String: PolicyCanvasEdgeRoute] {
  processed.reduce(into: [:]) { routes, entry in
    guard let originalRoute = original[entry.key] else {
      routes[entry.key] = entry.value
      return
    }
    routes[entry.key] = policyCanvasRoutePreservingTerminalStubs(
      original: originalRoute,
      processed: entry.value
    )
  }
}

func policyCanvasRoutePreservingTerminalStubs(
  original: PolicyCanvasEdgeRoute,
  processed: PolicyCanvasEdgeRoute
) -> PolicyCanvasEdgeRoute {
  guard original.points.count >= 2, processed.points.count >= 2 else {
    return processed
  }
  var points: [CGPoint] = []
  policyCanvasAppendOrthogonalBridge(original.points[0], to: &points)
  policyCanvasAppendOrthogonalBridge(original.points[1], to: &points)
  for point in processed.points.dropFirst().dropLast() {
    policyCanvasAppendOrthogonalBridge(point, to: &points)
  }
  policyCanvasAppendOrthogonalBridge(original.points[original.points.count - 2], to: &points)
  policyCanvasAppendOrthogonalBridge(original.points[original.points.count - 1], to: &points)
  let compressed = policyCanvasCompressPreservingTerminalStubs(points)
  return PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
}

private func policyCanvasAppendOrthogonalBridge(_ point: CGPoint, to points: inout [CGPoint]) {
  guard let last = points.last else {
    points.append(point)
    return
  }
  if abs(last.x - point.x) > 0.001, abs(last.y - point.y) > 0.001 {
    points.append(CGPoint(x: point.x, y: last.y))
  }
  if points.last != point {
    points.append(point)
  }
}
