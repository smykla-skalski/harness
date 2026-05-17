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

  /// Shift the longest internal bus segment perpendicular to itself by
  /// `lane * laneSpreadStep`, pushing each lane's shared corridor into its own
  /// visual track. Simple 4-point detours keep the older "skip large endpoint
  /// deltas" guard, while longer multi-bend routes spread their dominant
  /// interior run unconditionally because the offset no longer creates a
  /// visible endpoint zig-zag.
  static func applyLaneSpread(
    _ points: [CGPoint],
    lane: Int,
    source: CGPoint,
    target: CGPoint,
    lineSpacing: CGFloat = PolicyCanvasLayout.defaultEdgeLineSpacing
  ) -> [CGPoint] {
    guard lane != 0, points.count >= 4 else {
      return points
    }
    guard let segment = dominantInternalBusSegment(in: points) else {
      return points
    }
    let pointA = points[segment.startIndex]
    let offset = CGFloat(lane) * lineSpacing
    if segment.isHorizontal {
      if points.count == 4, abs(source.y - target.y) > 60 {
        return points
      }
      let midY = (source.y + target.y) / 2
      let direction: CGFloat = pointA.y >= midY ? 1 : -1
      var spread = points
      for index in dominantTrackIndices(in: points, segment: segment) {
        spread[index].y += direction * offset
      }
      return spread
    }
    if points.count == 4, abs(source.x - target.x) > 60 {
      return points
    }
    let midX = (source.x + target.x) / 2
    let direction: CGFloat = pointA.x >= midX ? 1 : -1
    var spread = points
    for index in dominantTrackIndices(in: points, segment: segment) {
      spread[index].x += direction * offset
    }
    return spread
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

  private struct InternalBusSegment {
    let startIndex: Int
    let endIndex: Int
    let isHorizontal: Bool
    let length: CGFloat
    let coordinate: CGFloat
  }

  private static func dominantInternalBusSegment(in points: [CGPoint]) -> InternalBusSegment? {
    guard points.count >= 4 else {
      return nil
    }
    return (1..<(points.count - 2)).compactMap { index in
      let start = points[index]
      let end = points[index + 1]
      if abs(start.y - end.y) < 0.001 {
        return InternalBusSegment(
          startIndex: index,
          endIndex: index + 1,
          isHorizontal: true,
          length: abs(end.x - start.x),
          coordinate: start.y
        )
      }
      if abs(start.x - end.x) < 0.001 {
        return InternalBusSegment(
          startIndex: index,
          endIndex: index + 1,
          isHorizontal: false,
          length: abs(end.y - start.y),
          coordinate: start.x
        )
      }
      return nil
    }
    .max { left, right in
      left.length < right.length
    }
  }

  private static func dominantTrackIndices(
    in points: [CGPoint],
    segment: InternalBusSegment
  ) -> ClosedRange<Int> {
    var startIndex = segment.startIndex
    var endIndex = segment.endIndex
    if segment.isHorizontal {
      while startIndex > 1,
        abs(points[startIndex - 1].y - segment.coordinate) < 0.001,
        abs(points[startIndex].y - segment.coordinate) < 0.001
      {
        startIndex -= 1
      }
      while endIndex < points.count - 2,
        abs(points[endIndex].y - segment.coordinate) < 0.001,
        abs(points[endIndex + 1].y - segment.coordinate) < 0.001
      {
        endIndex += 1
      }
      return startIndex...endIndex
    }
    while startIndex > 1,
      abs(points[startIndex - 1].x - segment.coordinate) < 0.001,
      abs(points[startIndex].x - segment.coordinate) < 0.001
    {
      startIndex -= 1
    }
    while endIndex < points.count - 2,
      abs(points[endIndex].x - segment.coordinate) < 0.001,
      abs(points[endIndex + 1].x - segment.coordinate) < 0.001
    {
      endIndex += 1
    }
    return startIndex...endIndex
  }
}
