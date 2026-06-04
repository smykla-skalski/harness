import CoreGraphics
import Foundation
import SwiftUI

struct PolicyCanvasParallelGroupBandCompactionInput {
  let groups: [PolicyCanvasNormalizedLayoutGroup]
  let edges: [PolicyCanvasLayoutEdge]
  let groupRanks: [String: Int]
  let layoutGroupIDByNodeID: [String: String]
  let configuration: PolicyCanvasLayoutConfiguration
}

// Compact parallel-branch groups so siblings share one rank band instead of being
// flung into separate columns and rows. The pass preserves each group as a rigid
// block and is a no-op for one-group-per-rank flows.
func policyCanvasCompactParallelGroupBands(
  input: PolicyCanvasParallelGroupBandCompactionInput,
  accumulator: inout PolicyCanvasUnconstrainedPlacement
) {
  PolicyCanvasParallelGroupBandCompactor(input: input).compact(accumulator: &accumulator)
}

private struct PolicyCanvasParallelGroupBandCompactor {
  let input: PolicyCanvasParallelGroupBandCompactionInput

  func compact(accumulator: inout PolicyCanvasUnconstrainedPlacement) {
    let groupsByRank = Dictionary(grouping: input.groups) { rank(for: $0) }
    guard groupsByRank.values.contains(where: { $0.count >= 2 }) else {
      return
    }
    let predecessors = predecessorsByGroup()
    var context = PolicyCanvasParallelBandContext(
      cursorX: input.groups.compactMap { currentFrame($0, accumulator: accumulator)?.minX }.min()
        ?? 0
    )

    for rank in groupsByRank.keys.sorted() {
      let rankGroups = groups(at: rank, accumulator: accumulator)
      guard !rankGroups.isEmpty else {
        continue
      }
      place(
        rankGroups: rankGroups,
        predecessors: predecessors,
        context: &context
      )
    }
    apply(translations: context.translation, accumulator: &accumulator)
  }

  private func rank(for group: PolicyCanvasNormalizedLayoutGroup) -> Int {
    input.groupRanks[group.layoutID] ?? 0
  }

  private func memberIDs(_ group: PolicyCanvasNormalizedLayoutGroup) -> [String] {
    group.nodeIDs.filter { input.layoutGroupIDByNodeID[$0] == group.layoutID }
  }

  private func currentFrame(
    _ group: PolicyCanvasNormalizedLayoutGroup,
    accumulator: PolicyCanvasUnconstrainedPlacement
  ) -> CGRect? {
    let frame = memberIDs(group).reduce(CGRect.null) { partial, nodeID in
      guard let position = accumulator.nodePositions[nodeID] else { return partial }
      return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
    }
    return frame.isNull ? nil : frame
  }

  private func predecessorsByGroup() -> [String: Set<String>] {
    var predecessors: [String: Set<String>] = [:]
    for edge in input.edges {
      guard
        let sourceGroup = input.layoutGroupIDByNodeID[edge.sourceNodeID],
        let targetGroup = input.layoutGroupIDByNodeID[edge.targetNodeID],
        sourceGroup != targetGroup,
        (input.groupRanks[sourceGroup] ?? 0) < (input.groupRanks[targetGroup] ?? 0)
      else {
        continue
      }
      predecessors[targetGroup, default: []].insert(sourceGroup)
    }
    return predecessors
  }

  private func groups(
    at rank: Int,
    accumulator: PolicyCanvasUnconstrainedPlacement
  ) -> [PolicyCanvasParallelRankGroup] {
    input.groups
      .filter { self.rank(for: $0) == rank }
      .compactMap { group in
        currentFrame(group, accumulator: accumulator).map { frame in
          PolicyCanvasParallelRankGroup(group: group, frame: frame)
        }
      }
  }

  private func place(
    rankGroups: [PolicyCanvasParallelRankGroup],
    predecessors: [String: Set<String>],
    context: inout PolicyCanvasParallelBandContext
  ) {
    let bandCenterY = centerY(
      for: rankGroups,
      predecessors: predecessors,
      knownCenters: context.newCenterY
    )
    let verticalGap = input.configuration.rowStep - PolicyCanvasLayout.nodeSize.height
    // Stack the PADDED group frames (member bounds plus the group's frame padding
    // and title chrome), not the bare member bounds. The bare-bounds stacking left
    // only `verticalGap - 2*padding` between boxes, so a lower group's title rode up
    // into the box above and a terminal the comb later dropped into the seam had no
    // clear room. Reserving the full frame opens a real inter-group seam while the
    // node ORDER is untouched, so crossings hold. Horizontal placement stays
    // member-based.
    let paddedFrames = rankGroups.map { policyCanvasGroupFrame(containing: $0.frame) }
    let totalHeight =
      paddedFrames.map(\.height).reduce(0, +)
      + (verticalGap * CGFloat(max(0, rankGroups.count - 1)))
    var cursorY = bandCenterY - (totalHeight / 2)
    var bandWidth: CGFloat = 0

    for (index, entry) in rankGroups.enumerated() {
      let memberTopY = cursorY + (entry.frame.minY - paddedFrames[index].minY)
      context.translation[entry.group.layoutID] = CGPoint(
        x: context.cursorX - entry.frame.minX,
        y: memberTopY - entry.frame.minY
      )
      context.newCenterY[entry.group.layoutID] = memberTopY + (entry.frame.height / 2)
      cursorY += paddedFrames[index].height + verticalGap
      bandWidth = max(bandWidth, entry.frame.width)
    }
    context.cursorX += bandWidth + input.configuration.interGroupSpacing
  }

  private func centerY(
    for rankGroups: [PolicyCanvasParallelRankGroup],
    predecessors: [String: Set<String>],
    knownCenters: [String: CGFloat]
  ) -> CGFloat {
    let predecessorCenters = rankGroups.flatMap { entry in
      (predecessors[entry.group.layoutID] ?? []).compactMap { knownCenters[$0] }
    }
    if predecessorCenters.isEmpty {
      return rankGroups.map(\.frame.midY).reduce(0, +) / CGFloat(rankGroups.count)
    }
    return predecessorCenters.reduce(0, +) / CGFloat(predecessorCenters.count)
  }

  private func apply(
    translations: [String: CGPoint],
    accumulator: inout PolicyCanvasUnconstrainedPlacement
  ) {
    for group in input.groups {
      guard let delta = translations[group.layoutID],
        let frame = currentFrame(group, accumulator: accumulator)
      else {
        continue
      }
      for nodeID in memberIDs(group) {
        guard let position = accumulator.nodePositions[nodeID] else { continue }
        accumulator.nodePositions[nodeID] = CGPoint(
          x: position.x + delta.x, y: position.y + delta.y)
      }
      let movedFrame = frame.offsetBy(dx: delta.x, dy: delta.y)
      accumulator.groupFramesByLayoutID[group.layoutID] = movedFrame
      if let actualGroupID = group.actualGroupID {
        accumulator.groupFrames[actualGroupID] = movedFrame
      }
    }
  }
}

private struct PolicyCanvasParallelRankGroup {
  let group: PolicyCanvasNormalizedLayoutGroup
  let frame: CGRect
}

private struct PolicyCanvasParallelBandContext {
  var cursorX: CGFloat
  var newCenterY: [String: CGFloat] = [:]
  var translation: [String: CGPoint] = [:]
}
