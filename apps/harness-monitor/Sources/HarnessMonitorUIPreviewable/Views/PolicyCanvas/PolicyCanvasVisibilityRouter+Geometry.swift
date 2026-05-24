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
    _ = lane
    _ = source
    _ = target
    _ = lineSpacing
    return points
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
    var bestLength: CGFloat = -1
    for index in 0..<points.count - 1 {
      let left = points[index]
      let right = points[index + 1]
      let horizontalLength = abs(right.x - left.x)
      if horizontalLength > bestLength {
        bestLength = horizontalLength
        bestIndex = index
      }
    }
    if bestLength < 0 {
      bestIndex = 0
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
