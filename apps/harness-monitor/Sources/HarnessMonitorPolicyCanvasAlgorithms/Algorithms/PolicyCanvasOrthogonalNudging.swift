import CoreGraphics

/// Global orthogonal nudging - the centering/separation pass an orthogonal
/// connector router runs after path search (Wybrow, Marriott, Stuckey,
/// "Orthogonal Connector Routing", 2010).
///
/// The first-feasible selector routes every edge independently, so members of a
/// fan-in (or any edges that happen to run the same corridor) are left stacked
/// collinearly on one lane. This pass takes every route together, finds the
/// segments that share an axis lane and overlap, and fans them into distinct
/// parallel lanes. Two properties keep the spread clean:
///
///   - Order within a shared channel is the barycentre of each segment's entry
///     and exit bends, so a member that arrives and leaves above its neighbour
///     takes the upper lane and the spread introduces no avoidable crossing
///     (the naive nudge that lacked this ordering swept rails across each other).
///   - The spread is bounded by the free space on each side of the channel, so a
///     nudged segment never moves into a node body.
///
/// Port stubs (a route's first and last segment) are pinned to their ports and
/// never nudged; they simply stretch to follow the interior segments they feed.
struct PolicyCanvasOrthogonalNudgingRouteProcessing: PolicyCanvasRoutePostProcessingAlgorithm {
  func processRoutes(
    input: PolicyCanvasRoutePostProcessingInput
  ) -> [String: PolicyCanvasEdgeRoute] {
    let obstacles = policyCanvasCanonicalObstacles(
      input.prepared.nodes.map(\.frame) + policyCanvasGroupTitleFrames(input.prepared.groups)
    )
    var pointsByEdge = input.routes.mapValues {
      PolicyCanvasVisibilityRouter.compressCollinear($0.points)
    }
    let processor = PolicyCanvasOrthogonalNudgeProcessor(
      obstacles: obstacles,
      fans: PolicyCanvasFanContext.make(from: pointsByEdge)
    )
    pointsByEdge = processor.nudged(pointsByEdge)
    return pointsByEdge.reduce(into: [:]) { result, entry in
      let points = PolicyCanvasVisibilityRouter.compressCollinear(entry.value)
      result[entry.key] = PolicyCanvasEdgeRoute(
        points: points,
        labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: points)
      )
    }
  }
}

/// One interior axis-aligned run of a route, tagged with everything the nudger
/// needs: the lane it sits on, the span it covers, and the perpendicular
/// coordinates of the bends on either side (for crossing-minimal ordering).
struct PolicyCanvasNudgeSegment {
  let edgeID: String
  let startIndex: Int
  let axis: PolicyCanvasSegmentAxis
  let position: CGFloat
  let lowerBound: CGFloat
  let upperBound: CGFloat
  let entryPerpendicular: CGFloat
  let exitPerpendicular: CGFloat
  /// Perpendicular coordinate the stub at the lower-span end connects to, and the
  /// same for the upper-span end. A stub leading to a larger coordinate than
  /// `position` heads "below"/"right" of this lane; a smaller one heads the other
  /// way. The non-fan ordering uses these to keep one member's drop-stub from
  /// cutting across a neighbour it was nudged above.
  let lowerConnection: CGFloat
  let upperConnection: CGFloat

  var orderingKey: CGFloat {
    (entryPerpendicular + exitPerpendicular) / 2
  }
}

struct PolicyCanvasOrthogonalNudgeProcessor {
  let obstacles: [CGRect]
  /// Fan membership of every edge, computed once from the initial routes. Lane
  /// ordering within a channel defers to this so a fan's corridor and column are
  /// ordered by one shared member rank and stay mutually crossing-free.
  let fans: PolicyCanvasFanContext
  /// Visual separation between adjacent lanes in a shared channel. Reused from
  /// the router's bus spacing so a nudged fan reads like the parallel rails the
  /// router already draws when it gets lanes right on its own.
  var laneGap: CGFloat = PolicyCanvasVisibilityRouter.laneSpreadStep
  /// Collinearity tolerance - segments within this of one another on the lane
  /// axis count as sharing the lane.
  var tolerance: CGFloat = 1
  /// Clearance kept between an outermost nudged lane and the nearest node body.
  var obstacleMargin: CGFloat = PolicyCanvasVisibilityRouter.channelStep
  /// Passes to run. Nudging an axis changes the perpendicular extent of the
  /// other axis's segments, so a second pass settles the residual overlap the
  /// first pass's shifts introduce; it converges well before this cap.
  var iterations: Int = 3

  func nudged(_ routes: [String: [CGPoint]]) -> [String: [CGPoint]] {
    var pointsByEdge = routes
    for _ in 0..<iterations {
      let shifts = shiftPass(pointsByEdge)
      guard !shifts.isEmpty else {
        break
      }
      apply(shifts, to: &pointsByEdge)
      pointsByEdge = pointsByEdge.mapValues { PolicyCanvasVisibilityRouter.compressCollinear($0) }
    }
    return pointsByEdge
  }

  /// One nudge pass: decompose, group both axes into channels, and accumulate a
  /// per-point shift for every channel that needs spreading.
  private func shiftPass(_ pointsByEdge: [String: [CGPoint]]) -> [String: [Int: CGVector]] {
    let segments = decompose(pointsByEdge)
    var shifts: [String: [Int: CGVector]] = [:]
    for axis in [PolicyCanvasSegmentAxis.horizontal, .vertical] {
      let channels = channels(in: segments.filter { $0.axis == axis })
      for channel in channels where channel.count > 1 {
        let offsets = laneOffsets(for: channel)
        for (segment, offset) in offsets where offset != 0 {
          let delta =
            axis == .horizontal
            ? CGVector(dx: 0, dy: offset)
            : CGVector(dx: offset, dy: 0)
          add(delta, edgeID: segment.edgeID, index: segment.startIndex, to: &shifts)
          add(delta, edgeID: segment.edgeID, index: segment.startIndex + 1, to: &shifts)
        }
      }
    }
    return shifts
  }

  private func add(
    _ delta: CGVector,
    edgeID: String,
    index: Int,
    to shifts: inout [String: [Int: CGVector]]
  ) {
    let existing = shifts[edgeID]?[index] ?? .zero
    shifts[edgeID, default: [:]][index] = CGVector(
      dx: existing.dx + delta.dx,
      dy: existing.dy + delta.dy
    )
  }

  private func apply(
    _ shifts: [String: [Int: CGVector]],
    to pointsByEdge: inout [String: [CGPoint]]
  ) {
    for (edgeID, perPoint) in shifts {
      guard var points = pointsByEdge[edgeID] else {
        continue
      }
      for (index, delta) in perPoint where index < points.count {
        points[index] = CGPoint(x: points[index].x + delta.dx, y: points[index].y + delta.dy)
      }
      pointsByEdge[edgeID] = points
    }
  }

  /// Split every route into interior axis-aligned segments. The first and last
  /// segment of each route are port stubs - pinned to the port - so they are
  /// excluded; they still move because they share a point with the interior
  /// segment they feed.
  private func decompose(_ pointsByEdge: [String: [CGPoint]]) -> [PolicyCanvasNudgeSegment] {
    var segments: [PolicyCanvasNudgeSegment] = []
    for (edgeID, points) in pointsByEdge where points.count >= 4 {
      for index in 1..<(points.count - 2) {
        let start = points[index]
        let end = points[index + 1]
        let deltaX = abs(start.x - end.x)
        let deltaY = abs(start.y - end.y)
        let axis: PolicyCanvasSegmentAxis
        if deltaY <= tolerance, deltaX > tolerance {
          axis = .horizontal
        } else if deltaX <= tolerance, deltaY > tolerance {
          axis = .vertical
        } else {
          continue
        }
        let beforePerp = axis == .horizontal ? points[index - 1].y : points[index - 1].x
        let afterPerp = axis == .horizontal ? points[index + 2].y : points[index + 2].x
        let startSpan = axis == .horizontal ? start.x : start.y
        let endSpan = axis == .horizontal ? end.x : end.y
        let startIsLower = startSpan <= endSpan
        segments.append(
          PolicyCanvasNudgeSegment(
            edgeID: edgeID,
            startIndex: index,
            axis: axis,
            position: axis == .horizontal ? start.y : start.x,
            lowerBound: min(startSpan, endSpan),
            upperBound: max(startSpan, endSpan),
            entryPerpendicular: beforePerp,
            exitPerpendicular: afterPerp,
            lowerConnection: startIsLower ? beforePerp : afterPerp,
            upperConnection: startIsLower ? afterPerp : beforePerp
          )
        )
      }
    }
    return segments
  }
}
