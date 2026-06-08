import CoreGraphics

private struct PolicyCanvasTaggedSegment {
  let edgeID: String
  let segment: PolicyCanvasRouteSegment
}

private struct PolicyCanvasCorridorKey: Hashable {
  let edgeA: String
  let edgeB: String
  let horizontal: Bool
  let collinear: Bool
}

/// Measure corridor reuse between routes. Interior segments (port stubs
/// excluded) of different edges are compared pairwise: same-lane segments that
/// overlap are a collinear stack (one wire reusing another's corridor); parallel
/// same-axis segments within the minimum separation crowd each other. One
/// violation per edge pair / axis / kind, keeping the longest shared extent.
func policyCanvasMeasureCorridors(
  routedEdges: [PolicyCanvasRoutedEdge],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasCorridorViolation] {
  var segments: [PolicyCanvasTaggedSegment] = []
  for routed in routedEdges {
    let all = policyCanvasRouteSegments(routed.route)
    guard all.count > 2 else {
      continue
    }
    for segment in all.dropFirst().dropLast() {
      segments.append(PolicyCanvasTaggedSegment(edgeID: routed.edge.id, segment: segment))
    }
  }
  var best: [PolicyCanvasCorridorKey: PolicyCanvasCorridorViolation] = [:]
  for leftIndex in segments.indices {
    for rightIndex in segments.index(after: leftIndex)..<segments.endIndex {
      let lhs = segments[leftIndex]
      let rhs = segments[rightIndex]
      guard lhs.edgeID != rhs.edgeID, lhs.segment.isSameAxis(as: rhs.segment) else {
        continue
      }
      let overlap = lhs.segment.overlap(with: rhs.segment)
      guard overlap >= thresholds.corridorOverlap else {
        continue
      }
      let separation = lhs.segment.axisDistance(to: rhs.segment)
      let collinear = lhs.segment.sharesAxisLane(with: rhs.segment)
      let parallelTooClose =
        !collinear && separation > 0.001 && separation < thresholds.minimumCorridorSeparation
      guard collinear || parallelTooClose else {
        continue
      }
      let edgeA = min(lhs.edgeID, rhs.edgeID)
      let edgeB = max(lhs.edgeID, rhs.edgeID)
      let extent = policyCanvasCorridorOverlapExtent(lhs.segment, rhs.segment)
      let violation = PolicyCanvasCorridorViolation(
        kind: collinear ? .collinear : .parallelTooClose,
        isHorizontal: lhs.segment.isHorizontal,
        edgeA: edgeA,
        edgeB: edgeB,
        overlapStart: extent.start,
        overlapEnd: extent.end,
        separation: separation
      )
      let key = PolicyCanvasCorridorKey(
        edgeA: edgeA,
        edgeB: edgeB,
        horizontal: lhs.segment.isHorizontal,
        collinear: collinear
      )
      if let existing = best[key] {
        if policyCanvasCorridorExtentLength(violation) > policyCanvasCorridorExtentLength(existing) {
          best[key] = violation
        }
      } else {
        best[key] = violation
      }
    }
  }
  return best.values.sorted(by: policyCanvasCorridorViolationOrder)
}

private func policyCanvasCorridorOverlapExtent(
  _ lhs: PolicyCanvasRouteSegment,
  _ rhs: PolicyCanvasRouteSegment
) -> (start: CGPoint, end: CGPoint) {
  if lhs.isHorizontal {
    let low = max(min(lhs.start.x, lhs.end.x), min(rhs.start.x, rhs.end.x))
    let high = min(max(lhs.start.x, lhs.end.x), max(rhs.start.x, rhs.end.x))
    return (CGPoint(x: low, y: lhs.start.y), CGPoint(x: high, y: lhs.start.y))
  }
  let low = max(min(lhs.start.y, lhs.end.y), min(rhs.start.y, rhs.end.y))
  let high = min(max(lhs.start.y, lhs.end.y), max(rhs.start.y, rhs.end.y))
  return (CGPoint(x: lhs.start.x, y: low), CGPoint(x: lhs.start.x, y: high))
}

private func policyCanvasCorridorExtentLength(_ violation: PolicyCanvasCorridorViolation) -> CGFloat {
  abs(violation.overlapEnd.x - violation.overlapStart.x)
    + abs(violation.overlapEnd.y - violation.overlapStart.y)
}

private func policyCanvasCorridorViolationOrder(
  _ lhs: PolicyCanvasCorridorViolation,
  _ rhs: PolicyCanvasCorridorViolation
) -> Bool {
  if lhs.edgeA != rhs.edgeA {
    return lhs.edgeA < rhs.edgeA
  }
  if lhs.edgeB != rhs.edgeB {
    return lhs.edgeB < rhs.edgeB
  }
  if lhs.kind != rhs.kind {
    return lhs.kind.rawValue < rhs.kind.rawValue
  }
  return (lhs.isHorizontal ? 0 : 1) < (rhs.isHorizontal ? 0 : 1)
}
