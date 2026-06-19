import CoreGraphics

extension PolicyCanvasOrthogonalNudgingRouteProcessing {
  func crowdedCorridorChannels(
    in segments: [PolicyCanvasNudgeSegment]
  ) -> [[PolicyCanvasNudgeSegment]] {
    var channels: [[PolicyCanvasNudgeSegment]] = []
    let sorted = segments.sorted(by: exactChannelSort)
    guard sorted.count > 1 else {
      return []
    }
    var parent = Array(sorted.indices)
    for left in sorted.indices {
      for right in sorted.index(after: left)..<sorted.endIndex {
        let laneDistance = sorted[right].position - sorted[left].position
        if laneDistance >= laneGap - 0.001 {
          break
        }
        guard sorted[left].edgeID != sorted[right].edgeID,
          spanOverlap(sorted[left], sorted[right]) >= overlapThreshold
        else {
          continue
        }
        union(left, right, parent: &parent)
      }
    }
    var groups: [Int: [PolicyCanvasNudgeSegment]] = [:]
    for index in sorted.indices {
      groups[find(index, parent: &parent), default: []].append(sorted[index])
    }
    channels.append(
      contentsOf: groups.values
        .filter { $0.count > 1 }
        .map { $0.sorted(by: exactChannelSort) }
    )
    return channels.sorted { left, right in
      key(for: left) < key(for: right)
    }
  }

  func fullLaneOffsets(
    for channel: [PolicyCanvasNudgeSegment],
    processor: PolicyCanvasOrthogonalNudgeProcessor
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    let orderedChannel = processor.orderedChannel(channel)
    guard orderedChannel.count > 1 else {
      return []
    }
    let laneCenter = orderedChannel.map(\.position).reduce(0, +) / CGFloat(orderedChannel.count)
    let center = CGFloat(orderedChannel.count - 1) / 2
    let firstLane = PolicyCanvasLayout.routeGridRound(laneCenter - (center * laneGap))
    return orderedChannel.enumerated().map { rank, segment in
      let targetPosition = firstLane + (CGFloat(rank) * laneGap)
      return (segment, targetPosition - segment.position)
    }
  }

  func localPairLaneOffsets(
    for channel: [PolicyCanvasNudgeSegment]
  ) -> [(segment: PolicyCanvasNudgeSegment, offset: CGFloat)] {
    let orderedChannel = channel.sorted(by: exactChannelSort)
    guard orderedChannel.count > 1 else {
      return []
    }
    let laneCenter = orderedChannel.map(\.position).reduce(0, +) / CGFloat(orderedChannel.count)
    let center = CGFloat(orderedChannel.count - 1) / 2
    let firstLane = PolicyCanvasLayout.routeGridRound(laneCenter - (center * laneGap))
    return orderedChannel.enumerated().map { rank, segment in
      let targetPosition = firstLane + (CGFloat(rank) * laneGap)
      return (segment, targetPosition - segment.position)
    }
  }

  func exactChannelSort(
    _ left: PolicyCanvasNudgeSegment,
    _ right: PolicyCanvasNudgeSegment
  ) -> Bool {
    if left.position != right.position {
      return left.position < right.position
    }
    if left.lowerBound != right.lowerBound {
      return left.lowerBound < right.lowerBound
    }
    if left.upperBound != right.upperBound {
      return left.upperBound < right.upperBound
    }
    if left.edgeID != right.edgeID {
      return left.edgeID < right.edgeID
    }
    return left.startIndex < right.startIndex
  }

  func spanOverlap(
    _ left: PolicyCanvasNudgeSegment,
    _ right: PolicyCanvasNudgeSegment
  ) -> CGFloat {
    max(0, min(left.upperBound, right.upperBound) - max(left.lowerBound, right.lowerBound))
  }

  func find(_ index: Int, parent: inout [Int]) -> Int {
    if parent[index] != index {
      parent[index] = find(parent[index], parent: &parent)
    }
    return parent[index]
  }

  func union(_ left: Int, _ right: Int, parent: inout [Int]) {
    let leftRoot = find(left, parent: &parent)
    let rightRoot = find(right, parent: &parent)
    guard leftRoot != rightRoot else {
      return
    }
    parent[rightRoot] = leftRoot
  }
}
