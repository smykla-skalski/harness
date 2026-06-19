import OSLog
import SwiftUI

extension PolicyCanvasPreparedRouteInput {
  func routesClearingCorridorReuse(
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

  func routesClearingCorridorsAndRestoringTerminalLeads(
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

  func routesRepairingResidualCorridorReuse(
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

  func residualCorridorReuseScore(
    _ violations: [PolicyCanvasCorridorViolation]
  ) -> (count: Int, length: CGFloat) {
    (
      violations.count,
      violations.reduce(CGFloat.zero) { total, violation in
        total + residualCorridorReuseLength(violation)
      }
    )
  }

  func residualCorridorReuseScore(
    _ candidate: (count: Int, length: CGFloat),
    improves current: (count: Int, length: CGFloat)
  ) -> Bool {
    candidate.count < current.count
      || (candidate.count == current.count && candidate.length < current.length - 0.001)
  }

  func residualCorridorReuseLength(_ violation: PolicyCanvasCorridorViolation) -> CGFloat {
    if violation.isHorizontal {
      return abs(violation.overlapEnd.x - violation.overlapStart.x)
    }
    return abs(violation.overlapEnd.y - violation.overlapStart.y)
  }

  var residualCorridorRepairOffsets: [CGFloat] {
    let step = PolicyCanvasVisibilityRouter.laneSpreadStep
    return [step, -step, step * 2, -(step * 2)]
  }

  func precomputedCorridorReuseViolations(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasCorridorViolation] {
    policyCanvasMeasureCorridors(
      routedEdges: precomputedRoutedEdges(routes: routes),
      thresholds: .default
    )
    .filter { $0.kind == .collinear }
  }

  func routeShiftingResidualCorridor(
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

  func residualCorridorSegmentIndex(
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

  func residualCorridorSegmentMatches(
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

  func residualCorridorSpanOverlaps(
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

  func residualCorridorShifted(
    _ point: CGPoint,
    violation: PolicyCanvasCorridorViolation,
    offset: CGFloat
  ) -> CGPoint {
    if violation.isHorizontal {
      return CGPoint(x: point.x, y: PolicyCanvasLayout.routeGridRound(point.y + offset))
    }
    return CGPoint(x: PolicyCanvasLayout.routeGridRound(point.x + offset), y: point.y)
  }
}
