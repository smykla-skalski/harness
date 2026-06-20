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
    let sharedPassContext = displayedRoutePassContext(nodeIndex: nodeIndex)
    let repairContext = PolicyCanvasCrossedPortRepairContext(
      nodeIndex: nodeIndex,
      maximumBodyHits: originalBodyHits,
      maximumTerminalSideMismatches: originalTerminalSideMismatches,
      router: selectedRouter,
      algorithms: algorithms,
      passContext: sharedPassContext
    )
    var currentRoutes = routes
    var currentViolations = precomputedCrossedPortViolations(
      routes: currentRoutes,
      nodeIndex: nodeIndex
    )
    // The node frames are fixed across the pass, so the broad-phase index is
    // built once. Each iteration's measurement baseline is rebuilt for the
    // current routes (one full measure), then every candidate folds in only the
    // edges it moved instead of re-measuring the whole graph.
    let nodeFramesByID = nodeIndex.mapValues(\.frame)
    let groupTitleFrames = policyCanvasGroupTitleFramesByID(groups)
    let nodeFrameIndex = PolicyCanvasNodeFrameIndex(framesByID: nodeFramesByID)
    let repairLimit = min(24, max(6, currentViolations.count))
    for _ in 0..<repairLimit {
      guard !currentViolations.isEmpty else {
        return currentRoutes
      }
      let baseline = PolicyCanvasRepairMeasurementBaseline(
        edges: edges, referenceRoutes: currentRoutes, nodeFramesByID: nodeFramesByID,
        groupTitleFrames: groupTitleFrames, nodeFrameIndex: nodeFrameIndex)
      let groupedCandidate = routesSwappingCrossedPortPairs(
        routes: currentRoutes,
        violations: currentViolations
      )
      let groupedViolations = baseline.crossedViolations(
        forCandidate: groupedCandidate,
        changedEdges: baseline.changedEdges(forCandidate: groupedCandidate))
      if let acceptedGroupedCandidate = crossedPortRepairCandidate(
        candidateRoutes: groupedCandidate,
        originalRoutes: currentRoutes,
        originalViolations: currentViolations,
        candidateViolations: groupedViolations,
        context: repairContext,
        baseline: baseline
      ) {
        currentRoutes = acceptedGroupedCandidate.routes
        currentViolations = acceptedGroupedCandidate.violations
        continue
      }
      guard
        let singleGroupCandidate = crossedPortSingleGroupRepairCandidate(
          routes: currentRoutes,
          violations: currentViolations,
          context: repairContext,
          baseline: baseline
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
    context: PolicyCanvasCrossedPortRepairContext,
    baseline: PolicyCanvasRepairMeasurementBaseline? = nil
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
            context: context,
            baseline: baseline
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
    context: PolicyCanvasCrossedPortRepairContext,
    baseline: PolicyCanvasRepairMeasurementBaseline? = nil
  ) -> PolicyCanvasCrossedPortRepairCandidate? {
    // `baseline` (when present) is keyed to `originalRoutes`, so it folds in only
    // the edges a candidate moved instead of re-measuring the whole graph. The
    // change set also subsumes the old full-dictionary inequality gate.
    let candidateChanged = baseline?.changedEdges(forCandidate: candidateRoutes)
    let candidateChangesRoutes =
      candidateChanged.map { !$0.isEmpty } ?? (candidateRoutes != originalRoutes)
    let candidateSideMismatches =
      baseline.map { $0.sideMismatchTotal(forCandidate: candidateRoutes, changedEdges: candidateChanged ?? []) }
      ?? precomputedTerminalSideMismatchCount(routes: candidateRoutes)
    guard candidateChangesRoutes,
      candidateSideMismatches <= context.maximumTerminalSideMismatches
    else {
      return nil
    }
    let candidateViolations =
      explicitCandidateViolations
      ?? baseline.map { $0.crossedViolations(forCandidate: candidateRoutes, changedEdges: candidateChanged ?? []) }
      ?? precomputedCrossedPortViolations(routes: candidateRoutes, nodeIndex: context.nodeIndex)
    guard candidateViolations.count < originalViolations.count else {
      return nil
    }
    let candidateBodyHits =
      baseline.map { $0.bodyHitTotal(forCandidate: candidateRoutes, changedEdges: candidateChanged ?? []) }
      ?? precomputedBodyHits(routes: candidateRoutes, nodeIndex: context.nodeIndex).count
    guard candidateBodyHits > context.maximumBodyHits else {
      return PolicyCanvasCrossedPortRepairCandidate(
        routes: candidateRoutes,
        violations: candidateViolations
      )
    }
    let candidateHitEdgeIDs = baseline.map {
      $0.bodyHitEdges(forCandidate: candidateRoutes, changedEdges: candidateChanged ?? [])
    }
    let bodyRepairedRoutes = precomputedRoutesRepairingBodyHits(
      routes: candidateRoutes,
      nodeIndex: context.nodeIndex,
      router: context.router,
      algorithms: context.algorithms,
      passContext: context.passContext,
      precomputedHitEdgeIDs: candidateHitEdgeIDs
    )
    let repairedChanged = baseline?.changedEdges(forCandidate: bodyRepairedRoutes)
    let repairedBodyHits =
      baseline.map { $0.bodyHitTotal(forCandidate: bodyRepairedRoutes, changedEdges: repairedChanged ?? []) }
      ?? precomputedBodyHits(routes: bodyRepairedRoutes, nodeIndex: context.nodeIndex).count
    let repairedSideMismatches =
      baseline.map { $0.sideMismatchTotal(forCandidate: bodyRepairedRoutes, changedEdges: repairedChanged ?? []) }
      ?? precomputedTerminalSideMismatchCount(routes: bodyRepairedRoutes)
    guard repairedBodyHits <= context.maximumBodyHits,
      repairedSideMismatches <= context.maximumTerminalSideMismatches
    else {
      return nil
    }
    let bodyRepairedViolations =
      baseline.map { $0.crossedViolations(forCandidate: bodyRepairedRoutes, changedEdges: repairedChanged ?? []) }
      ?? precomputedCrossedPortViolations(routes: bodyRepairedRoutes, nodeIndex: context.nodeIndex)
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
    let sharedPassContext = displayedRoutePassContext(nodeIndex: nodeIndex)
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
        algorithms: algorithms,
        passContext: sharedPassContext
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
    let sharedPassContext = displayedRoutePassContext(nodeIndex: nodeIndex)
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: sharedPassContext,
      router: selectedRouter,
      algorithms: algorithms
    )
    let crossedEdgeIDs = Set(originalViolations.flatMap { [$0.edgeA, $0.edgeB] })
    let selectedRoutes = policyCanvasSelectedRoutes(
      phase: "precomputed-crossed-port-repair",
      portMarkerLayout: markerLayout,
      context: context,
      edgeIDFilter: crossedEdgeIDs
    )
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
      algorithms: algorithms,
      passContext: sharedPassContext
    )
    return crossedPortRepairCandidate(
      candidateRoutes: repaired,
      originalRoutes: routes,
      originalViolations: originalViolations,
      context: repairContext
    )?.routes ?? routes
  }
}
