import SwiftUI

extension PolicyCanvasViewModel {
  func deleteSelectedComponent() -> PolicyCanvasDeletionRequest? {
    guard let selection else {
      notifyStatus("Select a node, group, or edge to delete")
      return nil
    }
    if canDeleteImmediately(selection) {
      delete(selection)
      return nil
    }
    return deletionRequest(for: selection)
  }

  func confirmDelete(_ request: PolicyCanvasDeletionRequest) {
    delete(request.selection)
  }

  private func canDeleteImmediately(_ selection: PolicyCanvasSelection) -> Bool {
    switch selection {
    case .node(let id):
      cleanEphemeralNodeIDs.contains(id) && incidentEdges(for: id).isEmpty
    case .edge(let id):
      cleanEphemeralEdgeIDs.contains(id)
    case .group(let id):
      nodes(in: id).isEmpty
    }
  }

  private func deletionRequest(
    for selection: PolicyCanvasSelection
  ) -> PolicyCanvasDeletionRequest? {
    switch selection {
    case .node(let id):
      guard let node = node(id) else { return nil }
      let incidentCount = incidentEdges(for: id).count
      let message =
        incidentCount == 0
        ? "Delete saved node \(node.title)?"
        : "Delete \(node.title) and \(incidentCount) connected edge(s)?"
      return PolicyCanvasDeletionRequest(
        selection: selection,
        title: "Delete node?",
        message: message,
        confirmationTitle: "Delete Node"
      )
    case .edge(let id):
      guard let edge = edges.first(where: { $0.id == id }) else { return nil }
      return PolicyCanvasDeletionRequest(
        selection: selection,
        title: "Delete connection?",
        message: "Delete connection \(edge.label)?",
        confirmationTitle: "Delete Connection"
      )
    case .group(let id):
      guard let group = group(id) else { return nil }
      let memberCount = nodes(in: id).count
      return PolicyCanvasDeletionRequest(
        selection: selection,
        title: "Delete group?",
        message: "Delete \(group.title)? \(memberCount) node(s) will stay on the canvas.",
        confirmationTitle: "Delete Group"
      )
    }
  }

  private func delete(_ selection: PolicyCanvasSelection) {
    switch selection {
    case .node(let id):
      deleteNode(id)
    case .edge(let id):
      deleteEdge(id)
    case .group(let id):
      deleteGroup(id)
    }
  }

  /// Removes the node and every edge incident on it. Clears the selection only
  /// when the deleted node was selected — foreign selections survive so the
  /// user's editing target persists across cascade deletes.
  func deleteNode(_ id: String) {
    guard let nodeIndex = nodes.firstIndex(where: { $0.id == id }) else {
      return
    }
    let title = nodes[nodeIndex].title
    nodes.remove(at: nodeIndex)
    edges.removeAll { edge in
      edge.source.nodeID == id || edge.target.nodeID == id
    }
    cleanEphemeralNodeIDs.remove(id)
    cleanEphemeralEdgeIDs = cleanEphemeralEdgeIDs.filter { edgeID in
      edges.contains { $0.id == edgeID }
    }
    if selection == .node(id) {
      selection = nil
    }
    reconcileGroupFrames()
    documentDirty = true
    clearTransientGestureState()
    invalidateValidationCache()
    notifyStatus("Deleted \(title)")
  }

  /// Removes the edge by id. Connected nodes are left intact. Clears the
  /// selection only when the deleted edge was the active selection.
  func deleteEdge(_ id: String) {
    guard let edgeIndex = edges.firstIndex(where: { $0.id == id }) else {
      return
    }
    let label = edges[edgeIndex].label
    edges.remove(at: edgeIndex)
    cleanEphemeralEdgeIDs.remove(id)
    if selection == .edge(id) {
      selection = nil
    }
    documentDirty = true
    clearTransientGestureState()
    invalidateValidationCache()
    notifyStatus("Deleted \(label) connection")
  }

  /// Removes the group container but keeps every member node on the canvas;
  /// each affected node has its `groupID` cleared. Clears the selection only
  /// when the deleted group was the active selection.
  func deleteGroup(_ id: String) {
    guard let groupIndex = groups.firstIndex(where: { $0.id == id }) else {
      return
    }
    let title = groups[groupIndex].title
    groups.remove(at: groupIndex)
    for index in nodes.indices where nodes[index].groupID == id {
      nodes[index].groupID = nil
    }
    if selection == .group(id) {
      selection = nil
    }
    reconcileGroupFrames()
    documentDirty = true
    clearTransientGestureState()
    invalidateValidationCache()
    notifyStatus("Deleted \(title)")
  }

  private func incidentEdges(for nodeID: String) -> [PolicyCanvasEdge] {
    edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }
  }
}
