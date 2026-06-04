import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  func reconcileGroupFrames() {
    let nodesByGroupID = Dictionary(
      grouping: nodes.compactMap { node -> (String, PolicyCanvasNode)? in
        guard let groupID = node.groupID else {
          return nil
        }
        return (groupID, node)
      }
    ) { $0.0 }
    .mapValues { entries in entries.map(\.1) }

    for index in groups.indices {
      guard
        let frame = policyCanvasGroupFrame(
          containing: nodesByGroupID[groups[index].id] ?? []
        )
      else {
        continue
      }
      groups[index].frame = frame
    }
  }

  func reconcileGroupFrame(id groupID: String) {
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      return
    }
    let members = nodes.filter { $0.groupID == groupID }
    guard let frame = policyCanvasGroupFrame(containing: members),
      groups[index].frame != frame
    else {
      return
    }
    groups[index].frame = frame
  }

  func seedGroupDrag(groupID: String, group: PolicyCanvasGroup) {
    if groupDragOrigins[groupID] == nil {
      groupDragOrigins[groupID] = group.frame
      let origins = nodes(in: groupID).map { ($0.id, $0.position) }
      groupNodeDragOrigins[groupID] = Dictionary(uniqueKeysWithValues: origins)
    }
  }

  func moveNodes(in groupID: String, by delta: CGSize) {
    let origins = groupNodeDragOrigins[groupID] ?? [:]
    for index in nodes.indices where nodes[index].groupID == groupID {
      guard let origin = origins[nodes[index].id] else {
        continue
      }
      let nextPosition = snapped(
        CGPoint(x: origin.x + delta.width, y: origin.y + delta.height)
      )
      if nodes[index].position != nextPosition {
        nodes[index].position = nextPosition
        markDocumentDirty()
      }
    }
  }

  func containingGroupID(
    for point: CGPoint,
    excluding excludedID: String? = nil
  ) -> String? {
    groups.first { group in
      group.id != excludedID && group.frame.contains(point)
    }?.id
  }

  func snapped(_ point: CGPoint) -> CGPoint {
    CGPoint(
      x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
      y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
    )
  }
}
