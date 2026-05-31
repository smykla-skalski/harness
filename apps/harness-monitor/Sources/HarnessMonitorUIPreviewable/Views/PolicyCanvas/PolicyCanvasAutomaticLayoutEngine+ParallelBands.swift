import CoreGraphics
import Foundation
import SwiftUI

// Compact parallel-branch groups so siblings share one rank band instead of being
// flung into separate columns and rows.
//
// The unconstrained engine places every group in sequence along X and centers
// each one independently on its members' Brandes-Köpf Y. For a linear group chain
// (one group per macro rank) that is exactly right - the groups read as a single
// left-to-right flow. But when a rank holds two or more sibling groups (parallel
// branches off a shared upstream group, e.g. a review lane and a deploy lane that
// both feed an outcomes lane), the sequential placement strings them out
// horizontally AND the global Y-assignment drifts them far apart vertically - one
// lane can sit a thousand points below its sibling. Edges between the upstream
// group and the lower lane then make enormous diagonal runs.
//
// This pass rebuilds the group bands by rank: every group at a rank shares one X
// band, the rank's siblings stack vertically a row-gap apart, and each rank's band
// follows the vertical center of the predecessors that feed it so the flow stays
// level. Each group is translated as a rigid block, so the within-group layout the
// engine already computed is preserved exactly. It runs only when a rank actually
// holds siblings; a one-group-per-rank layout is returned byte-for-byte unchanged.
func policyCanvasCompactParallelGroupBands(
  groups: [PolicyCanvasNormalizedLayoutGroup],
  edges: [PolicyCanvasLayoutEdge],
  groupRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String],
  configuration: PolicyCanvasLayoutConfiguration,
  accumulator: inout PolicyCanvasUnconstrainedPlacement
) {
  let groupsByRank = Dictionary(grouping: groups) { groupRanks[$0.layoutID] ?? 0 }
  guard groupsByRank.values.contains(where: { $0.count >= 2 }) else {
    return
  }

  func memberIDs(_ group: PolicyCanvasNormalizedLayoutGroup) -> [String] {
    group.nodeIDs.filter { layoutGroupIDByNodeID[$0] == group.layoutID }
  }
  func currentFrame(_ group: PolicyCanvasNormalizedLayoutGroup) -> CGRect? {
    let frame = memberIDs(group).reduce(CGRect.null) { partial, nodeID in
      guard let position = accumulator.nodePositions[nodeID] else { return partial }
      return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
    }
    return frame.isNull ? nil : frame
  }

  // A group's predecessors: groups one or more ranks upstream with an edge into it.
  var predecessors: [String: Set<String>] = [:]
  for edge in edges {
    guard
      let sourceGroup = layoutGroupIDByNodeID[edge.sourceNodeID],
      let targetGroup = layoutGroupIDByNodeID[edge.targetNodeID],
      sourceGroup != targetGroup,
      (groupRanks[sourceGroup] ?? 0) < (groupRanks[targetGroup] ?? 0)
    else {
      continue
    }
    predecessors[targetGroup, default: []].insert(sourceGroup)
  }

  let verticalGap = configuration.rowStep - PolicyCanvasLayout.nodeSize.height
  var cursorX = groups.compactMap { currentFrame($0)?.minX }.min() ?? 0
  var newCenterY: [String: CGFloat] = [:]
  var translation: [String: CGPoint] = [:]

  for rank in groupsByRank.keys.sorted() {
    let rankGroups = groups
      .filter { (groupRanks[$0.layoutID] ?? 0) == rank }
      .compactMap { group -> (group: PolicyCanvasNormalizedLayoutGroup, frame: CGRect)? in
        currentFrame(group).map { (group, $0) }
      }
    guard !rankGroups.isEmpty else { continue }

    let predecessorCenters = rankGroups.flatMap { entry in
      (predecessors[entry.group.layoutID] ?? []).compactMap { newCenterY[$0] }
    }
    let bandCenterY =
      predecessorCenters.isEmpty
      ? rankGroups.map(\.frame.midY).reduce(0, +) / CGFloat(rankGroups.count)
      : predecessorCenters.reduce(0, +) / CGFloat(predecessorCenters.count)

    let totalHeight =
      rankGroups.map(\.frame.height).reduce(0, +)
      + (verticalGap * CGFloat(max(0, rankGroups.count - 1)))
    var cursorY = bandCenterY - (totalHeight / 2)
    var bandWidth: CGFloat = 0
    for entry in rankGroups {
      translation[entry.group.layoutID] = CGPoint(
        x: cursorX - entry.frame.minX,
        y: cursorY - entry.frame.minY
      )
      newCenterY[entry.group.layoutID] = cursorY + (entry.frame.height / 2)
      cursorY += entry.frame.height + verticalGap
      bandWidth = max(bandWidth, entry.frame.width)
    }
    cursorX += bandWidth + configuration.interGroupSpacing
  }

  for group in groups {
    guard let delta = translation[group.layoutID], let frame = currentFrame(group) else {
      continue
    }
    for nodeID in memberIDs(group) {
      guard let position = accumulator.nodePositions[nodeID] else { continue }
      accumulator.nodePositions[nodeID] = CGPoint(x: position.x + delta.x, y: position.y + delta.y)
    }
    let movedFrame = frame.offsetBy(dx: delta.x, dy: delta.y)
    accumulator.groupFramesByLayoutID[group.layoutID] = movedFrame
    if let actualGroupID = group.actualGroupID {
      accumulator.groupFrames[actualGroupID] = movedFrame
    }
  }
}
