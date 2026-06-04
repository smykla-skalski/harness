import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Funnel appliers for node/edge/group lifecycle changes (add, remove,
/// move, restore). Split out of `PolicyCanvasViewModel+UndoFunnel.swift` to
/// keep that file under the 420-line cap; the dispatch funnel itself stays
/// in `+UndoFunnel`, the appliers live here. The property-edit appliers
/// (subtitle, title, kind, etc.) live in `+PropertyChangeAppliers.swift`
/// alongside their inspector callers.
extension PolicyCanvasViewModel {
  // MARK: - Node lifecycle

  func applyAddNode(
    _ node: PolicyCanvasNode,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    nodes.append(node)
    cleanEphemeralNodeIDs.insert(node.id)
    reconcileGroupFrames()
    selection = .node(node.id)
    return .removeNode(id: node.id, priorSelection: restoreSelection)
  }

  func applyRemoveNode(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedNode = nodes.first(where: { $0.id == id }) else {
      return .addNode(
        PolicyCanvasNode(id: id, title: id, kind: .source, position: .zero),
        restoreSelection: priorSelection
      )
    }
    let incidentEdges = edges.filter { edge in
      edge.source.nodeID == id || edge.target.nodeID == id
    }
    let cleanEphemeralNodeIncluded = cleanEphemeralNodeIDs.contains(id)
    let cleanEphemeralEdgeIDsCaptured = cleanEphemeralEdgeIDs.intersection(
      Set(incidentEdges.map(\.id))
    )
    nodes.removeAll { $0.id == id }
    edges.removeAll { edge in
      edge.source.nodeID == id || edge.target.nodeID == id
    }
    cleanEphemeralNodeIDs.remove(id)
    for edge in incidentEdges {
      cleanEphemeralEdgeIDs.remove(edge.id)
    }
    if selection == .node(id) {
      selection = nil
    }
    reconcileGroupFrames()
    clearTransientGestureState()
    return .restoreNode(
      removedNode,
      incidentEdges: incidentEdges,
      cleanEphemeralNodeIncluded: cleanEphemeralNodeIncluded,
      cleanEphemeralEdgeIDs: cleanEphemeralEdgeIDsCaptured,
      restoreSelection: priorSelection
    )
  }

  func applyRestoreNode(
    _ node: PolicyCanvasNode,
    incidentEdges: [PolicyCanvasEdge],
    cleanEphemeralNodeIncluded: Bool,
    cleanEphemeralEdgeIDs storedEdgeIDs: Set<String>,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    nodes.append(node)
    // If the daemon republished while this node was removed, an incident
    // edge may now reference a node that no longer exists locally. Filter
    // rather than crash — the user can replay the missing edge via remote
    // re-load (load-seam dirty-protect lets them keep their other local
    // edits). Live-node set is the freshly appended node id plus every
    // other id currently in `nodes`.
    let liveNodeIDs = Set(nodes.map(\.id))
    for edge in incidentEdges where !edges.contains(where: { $0.id == edge.id }) {
      guard
        liveNodeIDs.contains(edge.source.nodeID),
        liveNodeIDs.contains(edge.target.nodeID)
      else {
        continue
      }
      edges.append(edge)
    }
    if cleanEphemeralNodeIncluded {
      cleanEphemeralNodeIDs.insert(node.id)
    }
    for edgeID in storedEdgeIDs {
      cleanEphemeralEdgeIDs.insert(edgeID)
    }
    reconcileGroupFrames()
    selection = restoreSelection
    return .removeNode(id: node.id, priorSelection: restoreSelection)
  }

  func applyMoveNode(
    id: String,
    from: CGPoint,
    to: CGPoint,
    fromGroupID: String?,
    toGroupID: String?
  ) -> PolicyCanvasChange {
    guard let index = nodes.firstIndex(where: { $0.id == id }) else {
      return .moveNode(
        id: id,
        from: to,
        to: to,
        fromGroupID: toGroupID,
        toGroupID: fromGroupID
      )
    }
    nodes[index].layoutSource = .manual
    nodes[index].position = to
    // Replay the caller-supplied group membership when present (undo path),
    // otherwise compute auto-attach from the destination position the same
    // way drag-end and arrow-nudge do.
    let previousGroupID = nodes[index].groupID
    if let toGroupID {
      nodes[index].groupID = toGroupID
    } else if let groupID = containingGroupID(
      for: nodeCenter(nodes[index]),
      excluding: nodes[index].groupID
    ) {
      nodes[index].groupID = groupID
    } else if nodes[index].groupID == nil {
      nodes[index].groupID = containingGroupID(for: nodeCenter(nodes[index]))
    }
    for groupID in Set([previousGroupID, nodes[index].groupID].compactMap(\.self)) {
      reconcileGroupFrame(id: groupID)
    }
    return .moveNode(
      id: id,
      from: to,
      to: from,
      fromGroupID: nodes[index].groupID,
      toGroupID: fromGroupID ?? previousGroupID
    )
  }

  // MARK: - Edge lifecycle

  func applyAddEdge(
    _ edge: PolicyCanvasEdge,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    edges.append(edge)
    cleanEphemeralEdgeIDs.insert(edge.id)
    selection = .edge(edge.id)
    return .removeEdge(id: edge.id, priorSelection: restoreSelection)
  }

  func applyRemoveEdge(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedEdge = edges.first(where: { $0.id == id }) else {
      return .addEdge(
        PolicyCanvasEdge(
          id: id,
          source: PolicyCanvasPortEndpoint(nodeID: "", portID: "", kind: .output),
          target: PolicyCanvasPortEndpoint(nodeID: "", portID: "", kind: .input),
          label: ""
        ),
        restoreSelection: priorSelection
      )
    }
    let cleanEphemeralEdgeIncluded = cleanEphemeralEdgeIDs.contains(id)
    edges.removeAll { $0.id == id }
    cleanEphemeralEdgeIDs.remove(id)
    if selection == .edge(id) {
      selection = nil
    }
    clearTransientGestureState()
    return .restoreEdge(
      removedEdge,
      cleanEphemeralEdgeIncluded: cleanEphemeralEdgeIncluded,
      restoreSelection: priorSelection
    )
  }

  func applyRestoreEdge(
    _ edge: PolicyCanvasEdge,
    cleanEphemeralEdgeIncluded: Bool,
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    if !edges.contains(where: { $0.id == edge.id }) {
      edges.append(edge)
    }
    if cleanEphemeralEdgeIncluded {
      cleanEphemeralEdgeIDs.insert(edge.id)
    }
    selection = restoreSelection
    return .removeEdge(id: edge.id, priorSelection: restoreSelection)
  }

  // MARK: - Group lifecycle

  func applyMoveGroup(
    id: String,
    fromOrigin: CGPoint,
    toOrigin: CGPoint,
    memberOrigins: [String: CGPoint],
    memberDestinations: [String: CGPoint]
  ) -> PolicyCanvasChange {
    if let index = groups.firstIndex(where: { $0.id == id }) {
      groups[index].frame.origin = toOrigin
    }
    for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == id {
      if let destination = memberDestinations[nodes[nodeIndex].id] {
        nodes[nodeIndex].layoutSource = .manual
        nodes[nodeIndex].position = destination
      }
    }
    reconcileGroupFrame(id: id)
    return .moveGroup(
      id: id,
      fromOrigin: toOrigin,
      toOrigin: fromOrigin,
      memberOrigins: memberDestinations,
      memberDestinations: memberOrigins
    )
  }

  func applyRemoveGroup(
    id: String,
    priorSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    guard let removedGroup = groups.first(where: { $0.id == id }) else {
      return .restoreGroup(
        PolicyCanvasGroup(id: id, title: id, frame: .zero, tone: .intake),
        memberIDs: [],
        restoreSelection: priorSelection
      )
    }
    let formerMemberIDs = nodes.filter { $0.groupID == id }.map(\.id)
    groups.removeAll { $0.id == id }
    for nodeIndex in nodes.indices where nodes[nodeIndex].groupID == id {
      nodes[nodeIndex].groupID = nil
    }
    if selection == .group(id) {
      selection = nil
    }
    reconcileGroupFrames()
    clearTransientGestureState()
    return .restoreGroup(
      removedGroup,
      memberIDs: formerMemberIDs,
      restoreSelection: priorSelection
    )
  }

  func applyRestoreGroup(
    _ group: PolicyCanvasGroup,
    memberIDs: [String],
    restoreSelection: PolicyCanvasSelection?
  ) -> PolicyCanvasChange {
    if !groups.contains(where: { $0.id == group.id }) {
      groups.append(group)
    }
    let memberSet = Set(memberIDs)
    for nodeIndex in nodes.indices where memberSet.contains(nodes[nodeIndex].id) {
      nodes[nodeIndex].groupID = group.id
    }
    reconcileGroupFrames()
    selection = restoreSelection
    return .removeGroup(id: group.id, priorSelection: restoreSelection)
  }
}
