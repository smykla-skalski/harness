import SwiftUI

extension PolicyCanvasViewModel {
  /// Tick-rate node drag. Writes the new position directly each frame; the
  /// `mutate(_:)` funnel only enters on `endNodeDrag(_:translation:)` so the
  /// undo stack collects one entry per drag instead of one per frame.
  func dragNode(_ nodeID: String, translation: CGSize) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
      return
    }
    if nodeDragOrigins[nodeID] == nil {
      nodeDragOrigins[nodeID] = nodes[index].position
    }
    markNodeEdited(nodeID)
    let origin = nodeDragOrigins[nodeID] ?? nodes[index].position
    nodes[index].position = snapped(
      CGPoint(
        x: origin.x + translation.width / zoom,
        y: origin.y + translation.height / zoom
      )
    )
    highlightedGroupID =
      containingGroupID(for: nodeCenter(nodes[index]), excluding: nodes[index].groupID)
      ?? nodes[index].groupID
    reconcileGroupFrames()
    selection = .node(nodeID)
    documentDirty = true
  }

  /// End-of-gesture node drag. Computes the final landing position from the
  /// drag origin captured at gesture start, resets the tick-rate intermediate
  /// write, and routes the persisted move through `mutate(.moveNode)` so the
  /// drag collapses to a single undo step. No-op when the gesture produced
  /// no net movement (pure click).
  func endNodeDrag(_ nodeID: String, translation: CGSize) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else {
      highlightedGroupID = nil
      return
    }
    let origin = nodeDragOrigins[nodeID] ?? nodes[index].position
    let destination = snapped(
      CGPoint(
        x: origin.x + translation.width / zoom,
        y: origin.y + translation.height / zoom
      )
    )
    nodes[index].position = origin
    nodeDragOrigins[nodeID] = nil
    highlightedGroupID = nil
    if origin == destination {
      markNodeEdited(nodeID)
      reconcileGroupFrames()
      invalidateValidationCache()
      return
    }
    markNodeEdited(nodeID)
    let fromGroupID = nodes[index].groupID
    mutate(
      .moveNode(
        id: nodeID,
        from: origin,
        to: destination,
        fromGroupID: fromGroupID,
        toGroupID: nil
      )
    )
  }

  /// Tick-rate group drag. Like `dragNode`, writes directly per frame; the
  /// undo funnel only enters on `endGroupDrag`.
  func dragGroup(_ groupID: String, translation: CGSize) {
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      return
    }
    seedGroupDrag(groupID: groupID, group: groups[index])
    let origin = groupDragOrigins[groupID] ?? groups[index].frame
    let nextOrigin = snapped(
      CGPoint(
        x: origin.origin.x + translation.width / zoom,
        y: origin.origin.y + translation.height / zoom
      )
    )
    let delta = CGSize(
      width: nextOrigin.x - origin.origin.x,
      height: nextOrigin.y - origin.origin.y
    )
    groups[index].frame.origin = nextOrigin
    moveNodes(in: groupID, by: delta)
    reconcileGroupFrames()
    highlightedGroupID = groupID
    selection = .group(groupID)
    documentDirty = true
  }

  /// End-of-gesture group drag. Snapshots member positions at both the start
  /// and end of the gesture so `mutate(.moveGroup)` records a single
  /// invertible step; the live tick-rate writes are rolled back to the
  /// gesture-start state before the funnel reapplies the end state.
  func endGroupDrag(_ groupID: String, translation: CGSize) {
    guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
      highlightedGroupID = nil
      return
    }
    seedGroupDrag(groupID: groupID, group: groups[index])
    let groupOriginAtStart = groupDragOrigins[groupID] ?? groups[index].frame
    let memberOriginsAtStart = groupNodeDragOrigins[groupID] ?? [:]
    let toOrigin = snapped(
      CGPoint(
        x: groupOriginAtStart.origin.x + translation.width / zoom,
        y: groupOriginAtStart.origin.y + translation.height / zoom
      )
    )
    let delta = CGSize(
      width: toOrigin.x - groupOriginAtStart.origin.x,
      height: toOrigin.y - groupOriginAtStart.origin.y
    )
    let memberDestinations: [String: CGPoint] =
      memberOriginsAtStart.reduce(into: [:]) { partial, entry in
        partial[entry.key] = snapped(
          CGPoint(x: entry.value.x + delta.width, y: entry.value.y + delta.height)
        )
      }
    groups[index].frame.origin = groupOriginAtStart.origin
    for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == groupID {
      if let origin = memberOriginsAtStart[nodes[nodeIndex].id] {
        nodes[nodeIndex].position = origin
      }
    }
    groupDragOrigins[groupID] = nil
    groupNodeDragOrigins[groupID] = nil
    highlightedGroupID = nil
    if groupOriginAtStart.origin == toOrigin {
      reconcileGroupFrames()
      invalidateValidationCache()
      return
    }
    mutate(
      .moveGroup(
        id: groupID,
        fromOrigin: groupOriginAtStart.origin,
        toOrigin: toOrigin,
        memberOrigins: memberOriginsAtStart,
        memberDestinations: memberDestinations
      )
    )
  }
}
