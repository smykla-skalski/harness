import SwiftUI

func policyCanvasLabelCandidates(
  on segment: PolicyCanvasLabelRouteSegment,
  base: CGPoint,
  size: CGSize,
  options: PolicyCanvasLabelPlacementOptions,
  includesAdjacentFallback: Bool = false
) -> [CGPoint] {
  let preferAdjacentVerticalPlacement = options.preferAdjacentVerticalPlacement
  let preferAdjacentHorizontalPlacement = options.preferAdjacentHorizontalPlacement
  let labelAxisLength = segment.isHorizontal ? size.width : size.height
  let tRange: ClosedRange<CGFloat>?
  if options.keepsCornerClearance {
    tRange = segment.cornerClearRange(for: labelAxisLength)
  } else {
    tRange = segment.safeRange(for: labelAxisLength)
  }
  let parameters: [CGFloat]
  if let tRange {
    let baseT = min(max(segment.parameter(for: base), tRange.lowerBound), tRange.upperBound)
    let step = max(labelAxisLength + 12, PolicyCanvasLayout.gridSize * 2)
    let stepT = segment.length > 0 ? step / segment.length : 0
    // Walk outward from the base point along the segment so a crowded label can
    // slide *along* its own route to dodge a neighbour instead of being pushed
    // off the line. The signed lane offsets give the collision search several
    // spread-out positions to try.
    var values: [CGFloat] = [0.5, baseT, tRange.lowerBound, tRange.upperBound, 0.25, 0.75]
    for index in 1..<6 {
      values.append(baseT + (policyCanvasSignedLaneOffset(index: index, spacing: stepT)))
    }
    parameters = values.map { value in
      min(max(value, tRange.lowerBound), tRange.upperBound)
    }
  } else if preferAdjacentVerticalPlacement || preferAdjacentHorizontalPlacement {
    parameters = [0.5]
  } else {
    return []
  }
  let points = parameters.map(segment.point(at:))
  guard preferAdjacentVerticalPlacement || preferAdjacentHorizontalPlacement else {
    return points
  }
  var candidates: [CGPoint] = []
  for point in points {
    if preferAdjacentVerticalPlacement
      || (includesAdjacentFallback && segment.isVertical)
    {
      candidates.append(
        contentsOf: policyCanvasAdjacentVerticalLabelCandidates(
          point: point,
          base: base,
          labelWidth: size.width
        )
      )
    }
    if preferAdjacentHorizontalPlacement
      || (includesAdjacentFallback && segment.isHorizontal)
    {
      candidates.append(
        contentsOf: policyCanvasAdjacentHorizontalLabelCandidates(
          point: point,
          base: base,
          labelHeight: size.height
        )
      )
    }
    candidates.append(point)
  }
  return candidates
}

private func policyCanvasAdjacentVerticalLabelCandidates(
  point: CGPoint,
  base: CGPoint,
  labelWidth: CGFloat
) -> [CGPoint] {
  let primaryOffset = (labelWidth / 2) + PolicyCanvasLayout.gridSize + 6
  let secondaryOffset = primaryOffset + (PolicyCanvasLayout.gridSize * 2)
  let signs: [CGFloat] = base.x >= point.x ? [-1, 1] : [1, -1]
  return [primaryOffset, secondaryOffset].flatMap { magnitude in
    signs.map { sign in
      CGPoint(x: point.x + (sign * magnitude), y: point.y)
    }
  }
}

private func policyCanvasAdjacentHorizontalLabelCandidates(
  point: CGPoint,
  base: CGPoint,
  labelHeight: CGFloat
) -> [CGPoint] {
  let primaryOffset = (labelHeight / 2) + PolicyCanvasLayout.gridSize + 6
  let secondaryOffset = primaryOffset + (PolicyCanvasLayout.gridSize * 2)
  let signs: [CGFloat] = base.y >= point.y ? [-1, 1] : [1, -1]
  return [primaryOffset, secondaryOffset].flatMap { magnitude in
    signs.map { sign in
      CGPoint(x: point.x, y: point.y + (sign * magnitude))
    }
  }
}
