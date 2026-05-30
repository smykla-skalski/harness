import CoreGraphics

/// Source sides to try when emitting a corridor candidate. Always includes
/// the side that faces the corridor's vertical X (trailing if the corridor
/// is to the right of the source, leading if to the left). When the input
/// A* route picked a top/bottom port, also try that side so the corridor
/// candidate can keep a port-aligned shape; the corridor-facing side leads
/// the list so it wins ties.
///
/// Without this list the corridor candidate inherits whatever side the
/// flex-anchor router picked. For fan-out edges from a source with many
/// outputs, that's frequently the bottom side - which produces an awkward
/// down-then-right-then-up U-shape that loses scoring against the cheaper
/// bottom-port short-circuit. Letting the corridor candidate pick its own
/// natural side ensures the corridor route is competitive even when the
/// A* default is something else.
func policyCanvasCorridorAlignedSourceSides(
  inputSide: PolicyCanvasPortSide,
  sourceAnchor: CGPoint,
  corridorHint: PolicyCanvasEdgeCorridorHint
) -> [PolicyCanvasPortSide] {
  guard let corridorX = corridorHint.verticalLaneX else {
    return [inputSide]
  }
  let corridorFacingSide: PolicyCanvasPortSide =
    corridorX >= sourceAnchor.x ? .trailing : .leading
  if inputSide == corridorFacingSide {
    return [inputSide]
  }
  return [corridorFacingSide, inputSide]
}

/// Builds the corridor-aligned candidate set across every source/target side
/// combination consistent with the corridor hint. Used by the retry sweep
/// inside `policyCanvasCollisionAwareDisplayedRoute` so a corridor-shaped
/// route stays in the pool even after the flex-anchor A* has stopped
/// emitting the corridor-facing source side.
func policyCanvasCorridorAlignedCandidates(
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> [PolicyCanvasEdgeRoute] {
  guard let corridorHint = request.corridorHint, let corridorX = corridorHint.verticalLaneX else {
    return []
  }
  let sourceFacingSide: PolicyCanvasPortSide =
    corridorX >= request.sourceAnchor.point.x ? .trailing : .leading
  let sourceSides: Set<PolicyCanvasPortSide> = [
    sourceFacingSide,
    request.sourceAnchor.side,
  ]
  let targetSides: Set<PolicyCanvasPortSide> = Set(request.targetCandidates.map(\.side))
  var routes: [PolicyCanvasEdgeRoute] = []
  for sourceSide in sourceSides {
    for targetSide in targetSides {
      if let candidate = policyCanvasAlignedCorridorIntersectionRoute(
        request: request,
        sourceSide: sourceSide,
        targetSide: targetSide
      ) {
        routes.append(candidate)
      }
    }
  }
  // Always also synthesise a corridor candidate using the corridor-facing
  // source side directly from the node geometry. When portMarkerLayout has
  // collapsed `request.sourceCandidates` to a single side, the call above
  // can return the preferred anchor with the wrong side and the
  // orthogonality check inside `policyCanvasAlignedCorridorIntersectionRoute`
  // rejects the candidate. The synthesised anchor sits at the node's
  // trailing (or leading) midY based on the bottom-port position the layout
  // already encodes, so the corridor candidate stays in the pool regardless
  // of the round's marker state.
  if let synthesised = policyCanvasSynthesisedCorridorRoute(
    request: request,
    corridorX: corridorX,
    horizontalLaneY: corridorHint.horizontalLaneY,
    sourceFacingSide: sourceFacingSide
  ) {
    routes.append(synthesised)
  }
  return routes
}

private func policyCanvasSynthesisedCorridorRoute(
  request: PolicyCanvasResolvedDisplayedRouteRequest,
  corridorX: CGFloat,
  horizontalLaneY: CGFloat,
  sourceFacingSide: PolicyCanvasPortSide
) -> PolicyCanvasEdgeRoute? {
  let nodeWidth = PolicyCanvasLayout.nodeSize.width
  let nodeHeight = PolicyCanvasLayout.nodeSize.height
  let sourcePoint = request.sourceAnchor.point
  let sourceOrigin: CGPoint
  switch request.sourceAnchor.side {
  case .leading:
    sourceOrigin = CGPoint(x: sourcePoint.x, y: sourcePoint.y - nodeHeight / 2)
  case .trailing:
    sourceOrigin = CGPoint(x: sourcePoint.x - nodeWidth, y: sourcePoint.y - nodeHeight / 2)
  case .top:
    sourceOrigin = CGPoint(x: sourcePoint.x - nodeWidth / 2, y: sourcePoint.y)
  case .bottom:
    sourceOrigin = CGPoint(x: sourcePoint.x - nodeWidth / 2, y: sourcePoint.y - nodeHeight)
  }
  let syntheticSourceAnchor: CGPoint
  switch sourceFacingSide {
  case .trailing:
    syntheticSourceAnchor = CGPoint(
      x: sourceOrigin.x + nodeWidth, y: sourceOrigin.y + nodeHeight / 2)
  case .leading:
    syntheticSourceAnchor = CGPoint(x: sourceOrigin.x, y: sourceOrigin.y + nodeHeight / 2)
  case .top:
    syntheticSourceAnchor = CGPoint(x: sourceOrigin.x + nodeWidth / 2, y: sourceOrigin.y)
  case .bottom:
    syntheticSourceAnchor = CGPoint(
      x: sourceOrigin.x + nodeWidth / 2, y: sourceOrigin.y + nodeHeight)
  }
  guard let targetCandidate = request.targetCandidates.first else {
    return nil
  }
  let targetSide = targetCandidate.side
  // Synth uses the node's mid-edge anchor (not the actual lane-shifted
  // port), so we also use lane 0 for the escape - mixing the synthetic
  // anchor with a non-zero lane offset injects a lineSpacing-sized vertical
  // segment between the exit and the corridor entry that trips the artifact
  // penalty and lets a non-corridor A* route win on score alone.
  let sourceEscape = policyCanvasPortEscapeCandidate(
    from: syntheticSourceAnchor,
    side: sourceFacingSide,
    lane: 0,
    lineSpacing: request.lineSpacing
  )
  let targetEscape = policyCanvasPortEscapeCandidate(
    from: targetCandidate.point,
    side: targetSide,
    lane: 0,
    lineSpacing: request.lineSpacing
  )
  let horizontalRange =
    min(corridorX, targetEscape.routed.x)...max(corridorX, targetEscape.routed.x)
  let effectiveHorizontalLaneY = policyCanvasCorridorHorizontalLaneClearingTarget(
    hint: horizontalLaneY,
    targetSide: targetSide,
    targetAnchor: targetCandidate.point,
    lineSpacing: request.lineSpacing,
    obstacles: request.obstacles,
    horizontalRange: horizontalRange
  )
  let basePoints = [
    sourceEscape.routed,
    CGPoint(x: corridorX, y: sourceEscape.routed.y),
    CGPoint(x: corridorX, y: effectiveHorizontalLaneY),
    CGPoint(x: targetEscape.routed.x, y: effectiveHorizontalLaneY),
    targetEscape.routed,
  ]
  let compressedBase = PolicyCanvasVisibilityRouter.compressCollinear(basePoints)
  let baseRoute = PolicyCanvasEdgeRoute(
    points: compressedBase,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressedBase)
  )
  let bridged = policyCanvasBridgedRoute(
    baseRoute: baseRoute,
    source: sourceEscape,
    target: targetEscape
  )
  return bridged
}

/// Adjusts the corridor hint's horizontal lane Y so the synthesised corridor
/// route clears the target node body and every obstacle whose frame overlaps
/// the horizontal segment's X range before the final port-stub.
///
/// The hint's `horizontalLaneY` is computed by the layout engine as the
/// midpoint between source and target anchors. For a target arrival from the
/// top side the actual route should stay above the target's top edge instead
/// of crossing through it; symmetric for bottom arrivals. Without the target
/// clamp the corridor L-shape generated in
/// `policyCanvasAlignedCorridorIntersectionRoute` and
/// `policyCanvasAlignedVerticalDominantCorridorRoute` runs straight through
/// the target node, gets rejected as an obstacle intersection, and the router
/// falls back to a source-local lane that bypasses the corridor entirely.
///
/// The same L-shape can also clip a sibling node or a group title that sits
/// between the corridor's vertical lane X and the target. Without
/// obstacle-aware clearance the candidate is rejected just like the original
/// no-clearance case and the corridor is lost. When the caller supplies
/// `obstacles` and the horizontal segment's `horizontalRange`, the helper
/// walks up (or down) past any blocker whose Y range contains the candidate
/// lane and that sits inside the segment's X span.
///
/// The base `offset` mirrors `policyCanvasPreferredHorizontalCorridorY` in
/// the scoring layer (`max(lineSpacing * 1.5, gridSize * 2)`), so the
/// post-route scoring agrees with the route geometry on which Y the route
/// lives at.
func policyCanvasCorridorHorizontalLaneClearingTarget(
  hint: CGFloat,
  targetSide: PolicyCanvasPortSide,
  targetAnchor: CGPoint,
  lineSpacing: CGFloat,
  obstacles: [CGRect] = [],
  horizontalRange: ClosedRange<CGFloat>? = nil
) -> CGFloat {
  let offset = max(lineSpacing * 1.5, PolicyCanvasLayout.gridSize * 2)
  let margin = PolicyCanvasLayout.gridSize
  switch targetSide {
  case .top:
    let base = min(hint, targetAnchor.y - offset)
    return policyCanvasCorridorHorizontalLaneClearingTargetTop(
      base: base, margin: margin, obstacles: obstacles, horizontalRange: horizontalRange)
  case .bottom:
    let base = max(hint, targetAnchor.y + offset)
    return policyCanvasCorridorHorizontalLaneClearingTargetBottom(
      base: base, margin: margin, obstacles: obstacles, horizontalRange: horizontalRange)
  case .leading, .trailing:
    return hint
  }
}

private func policyCanvasCorridorHorizontalLaneClearingTargetTop(
  base: CGFloat,
  margin: CGFloat,
  obstacles: [CGRect],
  horizontalRange: ClosedRange<CGFloat>?
) -> CGFloat {
  guard let range = horizontalRange, !obstacles.isEmpty else { return base }
  let blockers = obstacles.filter { rect in
    rect.maxX >= range.lowerBound && rect.minX <= range.upperBound
  }
  guard !blockers.isEmpty else { return base }
  var candidate = base
  var safety = 32
  var changed = true
  while changed && safety > 0 {
    changed = false
    safety -= 1
    for rect in blockers
    where candidate >= rect.minY - 0.001 && candidate <= rect.maxY + 0.001 {
      candidate = rect.minY - margin
      changed = true
    }
  }
  return candidate
}

private func policyCanvasCorridorHorizontalLaneClearingTargetBottom(
  base: CGFloat,
  margin: CGFloat,
  obstacles: [CGRect],
  horizontalRange: ClosedRange<CGFloat>?
) -> CGFloat {
  guard let range = horizontalRange, !obstacles.isEmpty else { return base }
  let blockers = obstacles.filter { rect in
    rect.maxX >= range.lowerBound && rect.minX <= range.upperBound
  }
  guard !blockers.isEmpty else { return base }
  var candidate = base
  var safety = 32
  var changed = true
  while changed && safety > 0 {
    changed = false
    safety -= 1
    for rect in blockers
    where candidate >= rect.minY - 0.001 && candidate <= rect.maxY + 0.001 {
      candidate = rect.maxY + margin
      changed = true
    }
  }
  return candidate
}
