import HarnessMonitorKit
import SwiftUI

/// Default-layout helpers + overlap detection used by
/// `policyCanvasCleanInitialLayout(nodes:groups:)`. The default policy graph
/// gets a computed, centered arrangement instead of the older fixed
/// coordinates so dense terminal groups can fan out horizontally and the first
/// paint lands with balanced whitespace inside the minimum canvas.
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
  var groupsByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
  let nodeIndexByID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1.id, $0) })
  var nextGroupMinX: CGFloat = 0

  for layout in defaultPolicyCanvasGroupLayouts {
    let memberIndices = orderedDefaultPolicyMemberIndices(
      for: layout,
      nodes: nodes,
      nodeIndexByID: nodeIndexByID
    )
    guard !memberIndices.isEmpty else {
      continue
    }
    let columnCount = min(max(layout.maxColumns, 1), memberIndices.count)
    for (offset, nodeIndex) in memberIndices.enumerated() {
      let row = offset / columnCount
      let column = offset % columnCount
      nodes[nodeIndex].position = CGPoint(
        x: nextGroupMinX
          + PolicyCanvasLayout.groupHorizontalPadding
          + (CGFloat(column) * defaultPolicyCanvasColumnStep),
        y: PolicyCanvasLayout.groupVerticalPadding
          + (CGFloat(row) * defaultPolicyCanvasRowStep)
      )
    }
    let members = memberIndices.map { nodes[$0] }
    guard let frame = policyCanvasGroupFrame(containing: members) else {
      continue
    }
    groupsByID[layout.id]?.frame = frame
    nextGroupMinX = frame.maxX + defaultPolicyCanvasInterGroupSpacing
  }

  for index in groups.indices {
    if let frame = groupsByID[groups[index].id]?.frame {
      groups[index].frame = frame
    }
  }

  policyCanvasCenterInMinimumCanvas(nodes: &nodes, groups: &groups)
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

private let defaultPolicyCanvasInterGroupSpacing: CGFloat = 220
private let defaultPolicyCanvasColumnGap: CGFloat = 140
private let defaultPolicyCanvasRowGap: CGFloat = 140
private let defaultPolicyCanvasColumnStep =
  PolicyCanvasLayout.nodeSize.width + defaultPolicyCanvasColumnGap
private let defaultPolicyCanvasRowStep =
  PolicyCanvasLayout.nodeSize.height + defaultPolicyCanvasRowGap

private struct DefaultPolicyCanvasGroupLayout {
  let id: String
  let maxColumns: Int
  let preferredNodeOrder: [String]
}

private let defaultPolicyCanvasGroupLayouts: [DefaultPolicyCanvasGroupLayout] = [
  DefaultPolicyCanvasGroupLayout(
    id: "entry",
    maxColumns: 1,
    preferredNodeOrder: ["action:router"]
  ),
  DefaultPolicyCanvasGroupLayout(
    id: "merge",
    maxColumns: 1,
    preferredNodeOrder: ["evidence:merge", "risk:merge"]
  ),
  DefaultPolicyCanvasGroupLayout(
    id: "terminal",
    maxColumns: 2,
    preferredNodeOrder: [
      "supervisor:default-allow",
      "dry_run:mutate_repo",
      "human:unsafe-action",
      "consensus:protected-path",
      "human:missing-merge-evidence",
      "supervisor:merge-deny",
      "dry_run:high-risk-merge",
      "supervisor:auto-merge",
    ]
  ),
]

private func orderedDefaultPolicyMemberIndices(
  for layout: DefaultPolicyCanvasGroupLayout,
  nodes: [PolicyCanvasNode],
  nodeIndexByID: [String: Int]
) -> [Int] {
  let memberIndices = nodes.indices.filter { nodes[$0].groupID == layout.id }
  guard !memberIndices.isEmpty else {
    return []
  }
  let preferredOrder = Dictionary(
    uniqueKeysWithValues: layout.preferredNodeOrder.enumerated().map { ($1, $0) }
  )
  return memberIndices.sorted { left, right in
    let leftNode = nodes[left]
    let rightNode = nodes[right]
    let leftPreferred = preferredOrder[leftNode.id] ?? Int.max
    let rightPreferred = preferredOrder[rightNode.id] ?? Int.max
    if leftPreferred != rightPreferred {
      return leftPreferred < rightPreferred
    }
    return (nodeIndexByID[leftNode.id] ?? left) < (nodeIndexByID[rightNode.id] ?? right)
  }
}

private func policyCanvasCenterInMinimumCanvas(
  nodes: inout [PolicyCanvasNode],
  groups: inout [PolicyCanvasGroup]
) {
  let bounds = policyCanvasBounds(nodes: nodes, groups: groups)
  guard !bounds.isNull else {
    return
  }
  let targetCanvasWidth = max(
    PolicyCanvasLayout.minimumCanvasSize.width,
    bounds.width + (PolicyCanvasLayout.canvasTrailingPadding * 2)
  )
  let targetCanvasHeight = max(
    PolicyCanvasLayout.minimumCanvasSize.height,
    bounds.height + (PolicyCanvasLayout.canvasBottomPadding * 2)
  )
  let centeredMinX = max(
    PolicyCanvasLayout.initialContentOrigin.x,
    (targetCanvasWidth - bounds.width) / 2
  )
  let centeredMinY = max(
    PolicyCanvasLayout.initialContentOrigin.y,
    (targetCanvasHeight - bounds.height) / 2
  )
  let dx = centeredMinX - bounds.minX
  let dy = centeredMinY - bounds.minY
  guard dx != 0 || dy != 0 else {
    return
  }
  for index in nodes.indices {
    nodes[index].position.x += dx
    nodes[index].position.y += dy
  }
  for index in groups.indices {
    groups[index].frame = groups[index].frame.offsetBy(dx: dx, dy: dy)
  }
}
