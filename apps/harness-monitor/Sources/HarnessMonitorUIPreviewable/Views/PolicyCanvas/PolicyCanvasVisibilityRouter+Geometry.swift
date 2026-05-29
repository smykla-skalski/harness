import CoreGraphics

extension PolicyCanvasVisibilityRouter {
  static func compressCollinear(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count >= 3 else {
      return points
    }
    var result: [CGPoint] = [points[0]]
    for index in 1..<points.count - 1 {
      let prev = points[index - 1]
      let cur = points[index]
      let next = points[index + 1]
      let prevHorizontal = abs(cur.y - prev.y) < 0.0001
      let nextHorizontal = abs(next.y - cur.y) < 0.0001
      if prevHorizontal && nextHorizontal {
        continue
      }
      let prevVertical = abs(cur.x - prev.x) < 0.0001
      let nextVertical = abs(next.x - cur.x) < 0.0001
      if prevVertical && nextVertical {
        continue
      }
      result.append(cur)
    }
    result.append(points[points.count - 1])
    return result
  }

  static func applyLaneSpread(
    _ points: [CGPoint],
    lane: Int,
    source: CGPoint,
    target: CGPoint,
    lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
  ) -> [CGPoint] {
    _ = source
    _ = target
    _ = lineSpacing
    guard lane != 0, points.count >= 4 else {
      return points
    }
    let offset = policyCanvasSignedLaneOffset(index: lane, spacing: laneSpreadStep)
    guard offset != 0 else {
      return points
    }
    var bestIndex: Int?
    var bestLength: CGFloat = 0
    var bestAxis: PolicyCanvasSegmentAxis?
    for index in 1..<(points.count - 2) {
      let start = points[index]
      let end = points[index + 1]
      let dx = abs(end.x - start.x)
      let dy = abs(end.y - start.y)
      let length: CGFloat
      let axis: PolicyCanvasSegmentAxis
      if dy < 0.001, dx > 0.001 {
        length = dx
        axis = .horizontal
      } else if dx < 0.001, dy > 0.001 {
        length = dy
        axis = .vertical
      } else {
        continue
      }
      if length > bestLength {
        bestLength = length
        bestIndex = index
        bestAxis = axis
      }
    }
    guard let bestIndex, let bestAxis else {
      return points
    }
    var result = points
    switch bestAxis {
    case .horizontal:
      result[bestIndex].y += offset
      result[bestIndex + 1].y += offset
    case .vertical:
      result[bestIndex].x += offset
      result[bestIndex + 1].x += offset
    }
    return result
  }

  static func snapToChannels(_ points: [CGPoint], source: CGPoint, target: CGPoint) -> [CGPoint] {
    guard points.count > 2 else {
      return points
    }
    var snapped = points
    for index in 1..<snapped.count - 1 {
      snapped[index] = CGPoint(
        x: snap(snapped[index].x, step: channelStep),
        y: snap(snapped[index].y, step: channelStep)
      )
    }
    snapped[0] = source
    snapped[snapped.count - 1] = target
    preserveEndpointAxis(points: points, snapped: &snapped, endpointIndex: 0, adjacentIndex: 1)
    preserveEndpointAxis(
      points: points,
      snapped: &snapped,
      endpointIndex: points.count - 1,
      adjacentIndex: points.count - 2
    )
    return snapped
  }

  static func labelPosition(for points: [CGPoint]) -> CGPoint {
    guard points.count >= 2 else {
      return points.first ?? .zero
    }
    var bestIndex = 0
    var bestHorizontalLength: CGFloat = 0
    for index in 0..<points.count - 1 {
      let left = points[index]
      let right = points[index + 1]
      let horizontalLength = abs(right.x - left.x)
      if horizontalLength > bestHorizontalLength {
        bestHorizontalLength = horizontalLength
        bestIndex = index
      }
    }
    // Pure-vertical route -> no horizontal segment found. Pick the longest
    // segment by Euclidean length so the label sits on the long riser instead
    // of defaulting to a tiny port stub at index 0.
    if bestHorizontalLength == 0 {
      bestIndex = 0
      var bestLength: CGFloat = 0
      for index in 0..<points.count - 1 {
        let left = points[index]
        let right = points[index + 1]
        let length = hypot(right.x - left.x, right.y - left.y)
        if length > bestLength {
          bestLength = length
          bestIndex = index
        }
      }
    }
    let left = points[bestIndex]
    let right = points[bestIndex + 1]
    return CGPoint(x: (left.x + right.x) / 2, y: (left.y + right.y) / 2)
  }

  private static func snap(_ value: CGFloat, step: CGFloat) -> CGFloat {
    (value / step).rounded() * step
  }

  private static func preserveEndpointAxis(
    points: [CGPoint],
    snapped: inout [CGPoint],
    endpointIndex: Int,
    adjacentIndex: Int
  ) {
    let endpoint = points[endpointIndex]
    let adjacent = points[adjacentIndex]
    if abs(endpoint.x - adjacent.x) < 0.001 {
      snapped[adjacentIndex].x = snapped[endpointIndex].x
    }
    if abs(endpoint.y - adjacent.y) < 0.001 {
      snapped[adjacentIndex].y = snapped[endpointIndex].y
    }
  }
}
