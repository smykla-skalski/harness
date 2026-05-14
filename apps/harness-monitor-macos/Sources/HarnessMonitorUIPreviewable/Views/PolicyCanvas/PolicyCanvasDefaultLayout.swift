import HarnessMonitorKit
import SwiftUI

/// Default-layout helpers + overlap detection used by
/// `policyCanvasCleanInitialLayout(nodes:groups:)`. Pulled out of
/// `PolicyCanvasModelMapping.swift` so the mapping file stays under the
/// 420-line cap; the helpers themselves are unchanged.
func policyCanvasUsesDefaultPolicyGroups(_ groups: [PolicyCanvasGroup]) -> Bool {
  let groupIDs = Set(groups.map(\.id))
  return ["entry", "merge", "terminal"].allSatisfy(groupIDs.contains)
}

func policyCanvasNeedsDefaultArrangement(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> Bool {
  policyCanvasAnyGroupOverlap(groups)
    || policyCanvasAnyNodeOverlap(nodes)
    || policyCanvasAnyNodeOutsideAssignedGroup(nodes: nodes, groups: groups)
    || policyCanvasBounds(nodes: nodes, groups: groups).originNeedsNormalization
}

func applyDefaultPolicyCanvasLayout(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  for index in groups.indices {
    guard let frame = defaultPolicyCanvasGroupFrames[groups[index].id] else { continue }
    groups[index].frame = frame
  }
  for index in nodes.indices {
    guard let position = defaultPolicyCanvasNodePositions[nodes[index].id] else { continue }
    nodes[index].position = position
  }
}

func policyCanvasNormalizeMinimumOrigin(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> (nodes: [PolicyCanvasNode], groups: [PolicyCanvasGroup]) {
  let bounds = policyCanvasBounds(nodes: nodes, groups: groups)
  guard !bounds.isNull else {
    return (nodes, groups)
  }
  let dx = max(0, PolicyCanvasLayout.initialContentOrigin.x - bounds.minX)
  let dy = max(0, PolicyCanvasLayout.initialContentOrigin.y - bounds.minY)
  guard dx > 0 || dy > 0 else {
    return (nodes, groups)
  }
  var normalizedNodes = nodes
  var normalizedGroups = groups
  for index in normalizedNodes.indices {
    normalizedNodes[index].position.x += dx
    normalizedNodes[index].position.y += dy
  }
  for index in normalizedGroups.indices {
    normalizedGroups[index].frame = normalizedGroups[index].frame.offsetBy(dx: dx, dy: dy)
  }
  return (normalizedNodes, normalizedGroups)
}

func policyCanvasBounds(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> CGRect {
  let nodeBounds = nodes.reduce(CGRect.null) { partial, node in
    partial.union(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
  }
  return groups.reduce(nodeBounds) { partial, group in
    partial.union(group.frame)
  }
}

func policyCanvasAnyGroupOverlap(_ groups: [PolicyCanvasGroup]) -> Bool {
  for leftIndex in groups.indices {
    for rightIndex in groups.index(after: leftIndex)..<groups.endIndex
    where groups[leftIndex].frame.intersects(groups[rightIndex].frame) {
      return true
    }
  }
  return false
}

func policyCanvasAnyNodeOverlap(_ nodes: [PolicyCanvasNode]) -> Bool {
  for leftIndex in nodes.indices {
    for rightIndex in nodes.index(after: leftIndex)..<nodes.endIndex {
      let leftFrame = policyCanvasNodeFrame(nodes[leftIndex])
      let rightFrame = policyCanvasNodeFrame(nodes[rightIndex])
      if leftFrame.intersects(rightFrame) {
        return true
      }
    }
  }
  return false
}

func policyCanvasAnyNodeOutsideAssignedGroup(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup]
) -> Bool {
  let groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.frame) })
  return nodes.contains { node in
    guard let groupID = node.groupID, let groupFrame = groupsByID[groupID] else {
      return false
    }
    return !groupFrame.contains(policyCanvasNodeFrame(node))
  }
}

func policyCanvasNodeFrame(_ node: PolicyCanvasNode) -> CGRect {
  CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize)
}

func policyCanvasGroupFrame(containing bounds: CGRect) -> CGRect {
  let padded = bounds.insetBy(
    dx: -PolicyCanvasLayout.groupHorizontalPadding,
    dy: -PolicyCanvasLayout.groupVerticalPadding
  )
  let minX = padded.minX
  let minY = padded.minY
  let maxX = max(
    minX + PolicyCanvasLayout.minimumGroupSize.width,
    padded.maxX
  )
  let maxY = max(
    minY + PolicyCanvasLayout.minimumGroupSize.height,
    padded.maxY
  )
  return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    .integral
    .standardized
}

extension CGRect {
  var originNeedsNormalization: Bool {
    minX < PolicyCanvasLayout.initialContentOrigin.x
      || minY < PolicyCanvasLayout.initialContentOrigin.y
  }
}

let defaultPolicyCanvasGroupFrames: [String: CGRect] = [
  "entry": CGRect(x: 520, y: 520, width: 256, height: 220),
  "merge": CGRect(x: 1_060, y: 520, width: 256, height: 480),
  "terminal": CGRect(x: 2_140, y: 480, width: 256, height: 1_220),
]

let defaultPolicyCanvasNodePositions: [String: CGPoint] = [
  "action:router": CGPoint(x: 564, y: 572),
  "evidence:merge": CGPoint(x: 1_104, y: 572),
  "risk:merge": CGPoint(x: 1_104, y: 852),
  "supervisor:default-allow": CGPoint(x: 2_184, y: 532),
  "dry_run:mutate_repo": CGPoint(x: 2_184, y: 672),
  "human:unsafe-action": CGPoint(x: 2_184, y: 812),
  "human:missing-merge-evidence": CGPoint(x: 2_184, y: 952),
  "consensus:protected-path": CGPoint(x: 2_184, y: 1_092),
  "dry_run:high-risk-merge": CGPoint(x: 2_184, y: 1_232),
  "supervisor:merge-deny": CGPoint(x: 2_184, y: 1_372),
  "supervisor:auto-merge": CGPoint(x: 2_184, y: 1_512),
]
