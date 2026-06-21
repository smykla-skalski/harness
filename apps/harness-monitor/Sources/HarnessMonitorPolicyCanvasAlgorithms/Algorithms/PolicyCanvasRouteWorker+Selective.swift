import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  /// True when `edgeID` is in repair scope. A `nil` scope means the whole graph
  /// is in scope (first paint, drop, and every existing caller), so the repair
  /// passes behave exactly as before. A non-`nil` scope (the live drag recompute)
  /// freezes every out-of-scope edge: passes neither re-route nor perturb it, so
  /// it keeps the geometry the previous full reconverge already settled.
  func policyCanvasEdgeInRepairScope(_ edgeID: String, _ scope: Set<String>?) -> Bool {
    scope?.contains(edgeID) ?? true
  }

  /// Run the precomputed-route repair chain over an arbitrary seed route set:
  /// repair body hits, normalize terminal stubs, repair crossed ports, balance
  /// port markers, clear corridor reuse, fix terminal order, restore terminal
  /// leads, and reach rendered ports. The first-paint fast path and the live
  /// selective drag recompute share this so a dragged graph settles through the
  /// exact same passes as a seeded first paint.
  ///
  /// When `affectedEdgeIDs` is set, the chain repairs only those edges (plus any
  /// edge a moved node now crosses) and leaves the rest frozen. A node move only
  /// changes the optimal route of its incident edges, so scoping the passes to
  /// the affected edges reproduces the full-reconverge geometry while skipping the
  /// per-pass all-edges violation churn that dominates large graphs.
  func repairedRouteComputation(
    seedRoutes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    router selectedRouter: any PolicyCanvasEdgeRouter,
    algorithms: PolicyCanvasRoutingAlgorithmSet,
    affectedEdgeIDs: Set<String>? = nil
  ) -> PolicyCanvasPreparedRouteComputation {
    // Fold in any edge the moved nodes now cross so body-hit repair and the rest
    // of the chain treat it as affected and route it clear of the moved body.
    let scope: Set<String>? = affectedEdgeIDs.map { base in
      base.union(precomputedBodyHitEdgeIDs(routes: seedRoutes, nodeIndex: nodeIndex))
    }
    let bodySafeRoutes = precomputedRoutesRepairingBodyHits(
      routes: seedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms
    )
    let terminalSafeRoutes = precomputedRoutesNormalizingTerminalStubs(
      routes: bodySafeRoutes,
      nodeIndex: nodeIndex,
      affectedEdgeIDs: scope
    )
    let repairedRoutes = routesRepairingCrossedPorts(
      routes: terminalSafeRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      affectedEdgeIDs: scope
    )
    let terminalState = routesBalancingPrecomputedPortMarkers(
      routes: repairedRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      affectedEdgeIDs: scope
    )
    let routes = routesClearingCorridorReuse(
      routes: terminalState.routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      affectedEdgeIDs: scope
    )
    let portMarkerLayout = terminalState.portMarkerLayout
    let crossedPortRoutes = routesRepairingFinalTerminalOrder(
      routes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      portMarkerLayout: portMarkerLayout,
      affectedEdgeIDs: scope
    )
    let leadRestoredRoutes = routesClearingCorridorsAndRestoringTerminalLeads(
      routes: crossedPortRoutes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      affectedEdgeIDs: scope
    )
    let finalRoutes = routesReachingRenderedPorts(
      routes: leadRestoredRoutes,
      nodeIndex: nodeIndex,
      affectedEdgeIDs: scope
    )
    let finalPortMarkerLayout = precomputedRouteTerminalPortMarkerLayout(
      routes: finalRoutes,
      nodeIndex: nodeIndex,
      usesDeclarationOrderAnchor: true
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
  /// Re-route only the edges incident to a moved node, reusing the previous
  /// routes for every other edge. A node move perturbs the optimal route of its
  /// incident edges only (verified across every lab sample: a full reconverge
  /// after a move changes incident edges and nothing else), so routing just
  /// those edges against the shared obstacle/terminal/lane context reproduces the
  /// full-reconverge geometry while skipping the hundreds of edges a from-scratch
  /// converge would re-solve unchanged. This is libavoid's `SelectiveReroute` /
  /// yFiles' `ROUTE_AFFECTED_EDGES`, the documented live-drag technique
  /// (see `.bart/research/.../02-orthogonal-routing-performance-and-incremental-repair.md`).
  ///
  /// Returns `nil` when selective routing does not apply - the previous routes do
  /// not cover the current edge set (topology changed), or no edge is incident to
  /// the moved nodes - so the caller falls back to a full reconverge.
  public func selectiveRouteComputation(
    router defaultRouter: any PolicyCanvasEdgeRouter,
    algorithmSelection: PolicyCanvasAlgorithmSelection,
    movedNodeIDs: Set<String>,
    previousRoutes: [String: PolicyCanvasEdgeRoute],
    previousPortMarkerLayout: PolicyCanvasPortMarkerLayout
  ) -> PolicyCanvasPreparedRouteComputation? {
    let edgeIDs = Set(edges.map(\.id))
    guard previousRoutes.count == edgeIDs.count,
      Set(previousRoutes.keys) == edgeIDs
    else {
      return nil
    }
    let affectedEdgeIDs = Set(
      edges
        .filter {
          movedNodeIDs.contains($0.source.nodeID) || movedNodeIDs.contains($0.target.nodeID)
        }
        .map(\.id)
    )
    guard !affectedEdgeIDs.isEmpty else {
      return nil
    }

    let nodeIndex = nodeIndex
    let algorithms = PolicyCanvasAlgorithmRegistry.routingAlgorithms(for: algorithmSelection)
    let selectedRouter: any PolicyCanvasEdgeRouter =
      algorithmSelection.algorithmID(for: .edgeRouting)
        == PolicyCanvasAlgorithmDefaults.paddedOrthogonalVisibilityAStar
      ? defaultRouter
      : algorithms.edgeRouter
    let context = PolicyCanvasRouteStateContext(
      prepared: self,
      nodeIndex: nodeIndex,
      passContext: displayedRoutePassContext(nodeIndex: nodeIndex),
      router: selectedRouter,
      algorithms: algorithms
    )

    // Localized port-marker convergence: only the incident edges re-route each
    // pass; the unaffected routes stay pinned, so port-marker placement settles
    // to the same fixpoint a full reconverge reaches, but the A* search runs on a
    // handful of edges instead of the whole graph.
    var routes = previousRoutes
    var markerLayout = previousPortMarkerLayout
    for _ in 0..<3 {
      let affectedRoutes = policyCanvasSelectedRoutes(
        phase: "selective",
        portMarkerLayout: markerLayout,
        context: context,
        edgeIDFilter: affectedEdgeIDs
      )
      for id in affectedEdgeIDs where affectedRoutes[id] != nil {
        routes[id] = affectedRoutes[id]
      }
      let nextLayout = algorithms.portMarkerPlacement.placeMarkers(
        input: PolicyCanvasPortMarkerPlacementInput(
          prepared: self,
          routes: routes,
          nodeIndex: nodeIndex
        )
      )
      if nextLayout == markerLayout {
        break
      }
      markerLayout = nextLayout
    }

    // Settle the merged routes through the same repair chain a seeded first
    // paint uses, but scoped to the affected edges: body-hit repair folds in any
    // unrelated edge the moved node now crosses, then crossed-port / terminal-
    // order / reach passes finish them while every other edge stays frozen.
    return repairedRouteComputation(
      seedRoutes: routes,
      nodeIndex: nodeIndex,
      router: selectedRouter,
      algorithms: algorithms,
      affectedEdgeIDs: affectedEdgeIDs
    )
  }
}
