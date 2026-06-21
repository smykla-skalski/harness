import CoreGraphics

/// Cached body-hit and crossed-port measurement for a reference route set, so a
/// candidate that differs in only a few edges is measured by folding in just
/// those edges instead of re-scanning every edge. The crossed-port repair
/// evaluates hundreds of candidates per pass, each a small perturbation of the
/// current routes, so re-measuring the whole graph per candidate dominated first
/// paint on the largest samples.
///
/// Both folds are exact, not approximate:
/// - Body hits are independent per edge (each edge is tested against every other
///   node), so the total is the sum of per-edge counts; a candidate's total is
///   the baseline total minus the changed edges' baseline counts plus their
///   freshly measured counts.
/// - Crossed-port violations are computed independently per node side, and a
///   node side's violations depend only on the edges that attach a terminal
///   there. Recomputing exactly the sides whose terminals a candidate moved -
///   using each changed edge's candidate terminals and every unchanged edge's
///   baseline terminals - reproduces the full measure for those sides, and the
///   untouched sides keep their baseline violations verbatim.
struct PolicyCanvasRepairMeasurementBaseline {
  let edgesByID: [String: PolicyCanvasEdge]
  let referenceRoutes: [String: PolicyCanvasEdgeRoute]
  let nodeFramesByID: [String: CGRect]
  let groupTitleFrames: [(id: String, frame: CGRect)]
  let nodeFrameIndex: PolicyCanvasNodeFrameIndex
  let tolerance: CGFloat
  let bodyHitCountByEdge: [String: Int]
  let bodyHitTotal: Int
  let crossedRegistration: PolicyCanvasCrossedPortRegistration
  let crossedViolationsByNodeSide:
    [PolicyCanvasCrossedPortNodeSide: [PolicyCanvasCrossedPortsViolation]]
  let sideMismatchCountByEdge: [String: Int]
  let sideMismatchTotal: Int

  init(
    edges: [PolicyCanvasEdge],
    referenceRoutes: [String: PolicyCanvasEdgeRoute],
    nodeFramesByID: [String: CGRect],
    groupTitleFrames: [(id: String, frame: CGRect)],
    nodeFrameIndex: PolicyCanvasNodeFrameIndex
  ) {
    self.edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.referenceRoutes = referenceRoutes
    self.nodeFramesByID = nodeFramesByID
    self.groupTitleFrames = groupTitleFrames
    self.nodeFrameIndex = nodeFrameIndex
    let tolerance = PolicyCanvasLayout.portDiameter
    self.tolerance = tolerance

    let routedEdges = Self.routedEdges(edges: edges, routes: referenceRoutes)
    let bodyHits = policyCanvasMeasureBodyHits(
      routedEdges: routedEdges,
      nodeFramesByID: nodeFramesByID,
      groupTitleFrames: groupTitleFrames,
      nodeFrameIndex: nodeFrameIndex
    )
    var countByEdge: [String: Int] = [:]
    for violation in bodyHits {
      countByEdge[violation.edgeID, default: 0] += 1
    }
    bodyHitCountByEdge = countByEdge
    bodyHitTotal = bodyHits.count

    let registration = policyCanvasCrossedPortTerminalsByNodeSide(
      routedEdges: routedEdges, nodeFramesByID: nodeFramesByID, tolerance: tolerance)
    crossedRegistration = registration
    var violationsByNodeSide:
      [PolicyCanvasCrossedPortNodeSide: [PolicyCanvasCrossedPortsViolation]] = [:]
    for (nodeSide, terminals) in registration.terminalsByNodeSide {
      let violations = policyCanvasCrossedPortViolationsForSide(
        nodeSide, terminals: terminals, tolerance: tolerance)
      if !violations.isEmpty {
        violationsByNodeSide[nodeSide] = violations
      }
    }
    crossedViolationsByNodeSide = violationsByNodeSide

    var sideCountByEdge: [String: Int] = [:]
    var sideTotal = 0
    for edge in edges {
      guard let route = referenceRoutes[edge.id] else { continue }
      let count = Self.sideMismatchCount(edge: edge, route: route)
      if count > 0 {
        sideCountByEdge[edge.id] = count
      }
      sideTotal += count
    }
    sideMismatchCountByEdge = sideCountByEdge
    sideMismatchTotal = sideTotal
  }

  /// Terminal side-mismatch contribution of a single edge: how many of its two
  /// endpoints route into a side other than the endpoint's resolved port side.
  /// Independent per edge, so a candidate's total folds in only its changed edges.
  private static func sideMismatchCount(
    edge: PolicyCanvasEdge, route: PolicyCanvasEdgeRoute
  ) -> Int {
    var count = 0
    if policyCanvasRouteSourceSide(route) != policyCanvasResolvedPortSide(for: edge.source) {
      count += 1
    }
    if policyCanvasRouteTargetSide(route) != policyCanvasResolvedPortSide(for: edge.target) {
      count += 1
    }
    return count
  }

  /// The edges whose route differs from the reference set. Used both to gate the
  /// candidate (an empty set means the builder produced no change) and to scope
  /// the incremental folds. O(edges) of cheap route comparisons - the same cost
  /// as the full-dictionary inequality check it replaces.
  func changedEdges(
    forCandidate candidate: [String: PolicyCanvasEdgeRoute]
  ) -> Set<String> {
    var changed: Set<String> = []
    for (edgeID, route) in candidate where referenceRoutes[edgeID] != route {
      changed.insert(edgeID)
    }
    for edgeID in referenceRoutes.keys where candidate[edgeID] == nil {
      changed.insert(edgeID)
    }
    return changed
  }

  /// Total body-hit count for a candidate that differs from the reference routes
  /// only in `changedEdges`.
  func bodyHitTotal(
    forCandidate candidate: [String: PolicyCanvasEdgeRoute],
    changedEdges: Set<String>
  ) -> Int {
    var total = bodyHitTotal
    for edgeID in changedEdges {
      total -= bodyHitCountByEdge[edgeID] ?? 0
      guard let edge = edgesByID[edgeID], let route = candidate[edgeID],
        route.points.count >= 2
      else {
        continue
      }
      total +=
        policyCanvasMeasureBodyHits(
          routedEdges: [PolicyCanvasRoutedEdge(edge: edge, route: route)],
          nodeFramesByID: nodeFramesByID,
          groupTitleFrames: groupTitleFrames,
          nodeFrameIndex: nodeFrameIndex
        ).count
    }
    return total
  }

  /// Total terminal side-mismatch count for a candidate that differs from the
  /// reference routes only in `changedEdges`. Folds in just those edges, exactly
  /// reproducing the full per-edge scan because each edge's contribution is
  /// independent of the others.
  func sideMismatchTotal(
    forCandidate candidate: [String: PolicyCanvasEdgeRoute],
    changedEdges: Set<String>
  ) -> Int {
    var total = sideMismatchTotal
    for edgeID in changedEdges {
      total -= sideMismatchCountByEdge[edgeID] ?? 0
      guard let edge = edgesByID[edgeID], let route = candidate[edgeID] else {
        continue
      }
      total += Self.sideMismatchCount(edge: edge, route: route)
    }
    return total
  }

  /// The set of edge IDs with at least one body hit for a candidate that differs
  /// from the reference routes only in `changedEdges`. Reproduces the full
  /// `precomputedBodyHitEdgeIDs` scan exactly - body-hit membership is independent
  /// per edge, so unchanged edges keep their reference membership and only the
  /// changed edges are freshly tested against the prebuilt index.
  func bodyHitEdges(
    forCandidate candidate: [String: PolicyCanvasEdgeRoute],
    changedEdges: Set<String>
  ) -> Set<String> {
    var hits = Set(bodyHitCountByEdge.keys)
    for edgeID in changedEdges {
      hits.remove(edgeID)
      guard let edge = edgesByID[edgeID], let route = candidate[edgeID],
        route.points.count >= 2
      else {
        continue
      }
      let hit = !policyCanvasMeasureBodyHits(
        routedEdges: [PolicyCanvasRoutedEdge(edge: edge, route: route)],
        nodeFramesByID: nodeFramesByID,
        groupTitleFrames: groupTitleFrames,
        nodeFrameIndex: nodeFrameIndex
      ).isEmpty
      if hit {
        hits.insert(edgeID)
      }
    }
    return hits
  }

  /// Crossed-port violations for a candidate that differs from the reference
  /// routes only in `changedEdges`, sorted identically to the full measure.
  func crossedViolations(
    forCandidate candidate: [String: PolicyCanvasEdgeRoute],
    changedEdges: Set<String>
  ) -> [PolicyCanvasCrossedPortsViolation] {
    var candidateTerminalsByNodeSide:
      [PolicyCanvasCrossedPortNodeSide: [PolicyCanvasSideTerminal]] = [:]
    var affectedSides: Set<PolicyCanvasCrossedPortNodeSide> = []
    for edgeID in changedEdges {
      for nodeSide in crossedRegistration.nodeSidesByEdge[edgeID] ?? [] {
        affectedSides.insert(nodeSide)
      }
      guard let edge = edgesByID[edgeID], let route = candidate[edgeID] else {
        continue
      }
      for (point, nodeID) in [
        (route.points.first, edge.source.nodeID), (route.points.last, edge.target.nodeID),
      ] {
        guard let point,
          let resolved = policyCanvasResolveCrossedPortSideTerminal(
            point: point,
            routedEdge: PolicyCanvasRoutedEdge(edge: edge, route: route),
            nodeID: nodeID,
            nodeFramesByID: nodeFramesByID,
            tolerance: tolerance)
        else {
          continue
        }
        affectedSides.insert(resolved.nodeSide)
        candidateTerminalsByNodeSide[resolved.nodeSide, default: []].append(resolved.terminal)
      }
    }

    var result: [PolicyCanvasCrossedPortsViolation] = []
    for (nodeSide, violations) in crossedViolationsByNodeSide
    where !affectedSides.contains(nodeSide) {
      result.append(contentsOf: violations)
    }
    for nodeSide in affectedSides {
      var terminals =
        (crossedRegistration.terminalsByNodeSide[nodeSide] ?? [])
        .filter { !changedEdges.contains($0.edgeID) }
      terminals.append(contentsOf: candidateTerminalsByNodeSide[nodeSide] ?? [])
      result.append(
        contentsOf: policyCanvasCrossedPortViolationsForSide(
          nodeSide, terminals: terminals, tolerance: tolerance))
    }
    return result.sorted(by: policyCanvasCrossedPortsOrder)
  }

  private static func routedEdges(
    edges: [PolicyCanvasEdge],
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasRoutedEdge] {
    edges.compactMap { edge in
      guard let route = routes[edge.id], route.points.count >= 2 else {
        return nil
      }
      return PolicyCanvasRoutedEdge(edge: edge, route: route)
    }
  }
}
