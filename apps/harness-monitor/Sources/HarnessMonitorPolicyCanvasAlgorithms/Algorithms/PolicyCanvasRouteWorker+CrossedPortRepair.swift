import OSLog
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func routesRepairingCrossedPortOrder(
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

  func crossedPortSingleGroupRepairCandidate(
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

  func crossedPortRepairCandidate(
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

  func routesRepairingCrossedPorts(
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

  func routesRepairingCrossedPorts(
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
}
