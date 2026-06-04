import CoreGraphics

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

/// Channel grouping and lane-offset maths for the crossing-aware route
/// post-process (the global orthogonal nudge of Wybrow, Marriott, Stuckey,
/// "Orthogonal Connector Routing", 2010). Built once from the initial routes;
/// `channels(in:)` and `laneOffsets(for:)` (in the +Channels / +Fans companions)
/// read these to fan a stacked corridor into parallel lanes, ordered so no
/// member's drop-stub is swept across a neighbour it was nudged above.
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
}
