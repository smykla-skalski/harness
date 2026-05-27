extension PolicyCanvasViewModel {
  /// Choose the status line each change publishes. The strings match what the
  /// non-funnelled paths used before the refactor so existing tests that
  /// assert on status prefixes keep passing.
  func statusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .addNode,
      .restoreNode,
      .removeNode,
      .addEdge,
      .restoreEdge,
      .removeEdge,
      .restoreGroup,
      .removeGroup:
      return lifecycleStatusMessage(for: change, inverse: inverse)
    case .moveNode,
      .bulkMove,
      .reflowLayout,
      .moveGroup,
      .renameNode,
      .removeNodeFromGroup,
      .bulkAdd,
      .bulkRemove:
      return spatialOrBulkStatusMessage(for: change, inverse: inverse)
    case .setNodeTitle,
      .setNodeKind,
      .setNodeGroup,
      .setNodeSubtitle,
      .setNodePolicyKind,
      .setNodeAutomationBinding,
      .setEdgeCondition,
      .setEdgeLabel,
      .setEdgeKind,
      .setEdgePinnedPortSide,
      .setGroupTitle,
      .setGroupTone:
      return propertyStatusMessage(for: change)
    }
  }

  private func lifecycleStatusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .addNode,
      .restoreNode,
      .removeNode:
      return nodeLifecycleStatusMessage(for: change, inverse: inverse)
    case .addEdge,
      .restoreEdge,
      .removeEdge:
      return edgeLifecycleStatusMessage(for: change, inverse: inverse)
    case .restoreGroup,
      .removeGroup:
      return groupLifecycleStatusMessage(for: change, inverse: inverse)
    default:
      preconditionFailure("Unsupported lifecycle status")
    }
  }

  private func nodeLifecycleStatusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .addNode(let node, _):
      return "\(node.kind.title) node added"
    case .restoreNode(let node, _, _, _, _):
      return "Restored \(node.title)"
    case .removeNode:
      if case .restoreNode(let node, _, _, _, _) = inverse {
        return "Deleted \(node.title)"
      }
      return "Deleted node"
    default:
      preconditionFailure("Unsupported node lifecycle status")
    }
  }

  private func edgeLifecycleStatusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .addEdge:
      return "Edge created"
    case .restoreEdge(let edge, _, _):
      return "Restored \(edge.label) connection"
    case .removeEdge:
      if case .restoreEdge(let edge, _, _) = inverse {
        return "Deleted \(edge.label) connection"
      }
      return "Deleted connection"
    default:
      preconditionFailure("Unsupported edge lifecycle status")
    }
  }

  private func groupLifecycleStatusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .restoreGroup(let group, _, _):
      return "Restored \(group.title)"
    case .removeGroup:
      if case .restoreGroup(let group, _, _) = inverse {
        return "Deleted \(group.title)"
      }
      return "Deleted group"
    default:
      preconditionFailure("Unsupported group lifecycle status")
    }
  }

  private func spatialOrBulkStatusMessage(
    for change: PolicyCanvasChange,
    inverse: PolicyCanvasChange
  ) -> String {
    switch change {
    case .moveNode:
      return "Node moved"
    case .bulkMove(let nodeMoves, let groupMoves):
      return bulkMoveStatus(nodeCount: nodeMoves.count, groupCount: groupMoves.count)
    case .reflowLayout(let nodeChanges, let edgeChanges):
      if !nodeChanges.isEmpty {
        return "Reformatted \(nodeChanges.count) node\(nodeChanges.count == 1 ? "" : "s")"
      }
      if !edgeChanges.isEmpty {
        return "Refreshed edge ports"
      }
      return "Reformatted canvas"
    case .moveGroup:
      return "Group moved"
    case .renameNode(_, _, let to):
      return "Renamed to \(to)"
    case .removeNodeFromGroup(_, _, let toGroupID):
      if toGroupID == nil {
        return "Removed from group"
      }
      return "Moved to group"
    case .bulkAdd(let nodes, let edges, let groups, _, _, _):
      return pasteSummaryMessage(
        nodeCount: nodes.count,
        edgeCount: edges.count,
        groupCount: groups.count
      )
    case .bulkRemove:
      return bulkRemoveStatus(inverse: inverse)
    default:
      preconditionFailure("Unsupported spatial or bulk status")
    }
  }

  private func bulkMoveStatus(nodeCount: Int, groupCount: Int) -> String {
    let count = nodeCount + groupCount
    if count <= 1 {
      return "Moved selection"
    }
    return "Moved \(count) items"
  }

  private func bulkRemoveStatus(inverse: PolicyCanvasChange) -> String {
    if case .bulkAdd(let nodes, _, _, _, _, _) = inverse, !nodes.isEmpty {
      return "Removed \(nodes.count) item\(nodes.count == 1 ? "" : "s")"
    }
    return "Removed items"
  }

  private func propertyStatusMessage(for change: PolicyCanvasChange) -> String {
    if let message = nodePropertyStatusMessage(for: change) {
      return message
    }
    if let message = edgePropertyStatusMessage(for: change) {
      return message
    }
    if let message = groupPropertyStatusMessage(for: change) {
      return message
    }
    preconditionFailure("Unsupported property status")
  }

  private func nodePropertyStatusMessage(for change: PolicyCanvasChange) -> String? {
    switch change {
    case .setNodeTitle(_, _, let to):
      return "Title set to \(to)"
    case .setNodeKind(_, _, let to, _, _, _, _, _):
      return "Kind set to \(to.title)"
    case .setNodeGroup(_, _, let to):
      return to == nil ? "Removed from group" : "Moved to group"
    case .setNodeSubtitle(_, _, let to):
      return "Subtitle set to \(to)"
    case .setNodePolicyKind(_, _, let to):
      return to.map { "Node binding set to \($0.kind)" } ?? "Node binding cleared"
    case .setNodeAutomationBinding(_, _, let to):
      return to?.isEnabled == true ? "Automation policy configured" : "Automation policy cleared"
    default:
      return nil
    }
  }

  private func edgePropertyStatusMessage(for change: PolicyCanvasChange) -> String? {
    switch change {
    case .setEdgeCondition(_, _, let to):
      return "Condition set to \(to)"
    case .setEdgeLabel(_, _, let to):
      return "Edge label set to \(to)"
    case .setEdgeKind(_, _, let to):
      return "Edge kind set to \(to.accessibilityWord)"
    case .setEdgePinnedPortSide(_, _, let to):
      return to ? "Edge ports pinned" : "Edge ports unpinned"
    default:
      return nil
    }
  }

  private func groupPropertyStatusMessage(for change: PolicyCanvasChange) -> String? {
    switch change {
    case .setGroupTitle(_, _, let to):
      return "Group renamed to \(to)"
    case .setGroupTone(_, _, let to):
      return "Group tone set to \(to.policyCanvasTitle)"
    default:
      return nil
    }
  }

  func pasteSummaryMessage(
    nodeCount: Int,
    edgeCount: Int,
    groupCount: Int
  ) -> String {
    var parts: [String] = []
    if nodeCount > 0 {
      parts.append("\(nodeCount) node\(nodeCount == 1 ? "" : "s")")
    }
    if edgeCount > 0 {
      parts.append("\(edgeCount) edge\(edgeCount == 1 ? "" : "s")")
    }
    if groupCount > 0 {
      parts.append("\(groupCount) group\(groupCount == 1 ? "" : "s")")
    }
    guard !parts.isEmpty else {
      return "Pasted"
    }
    return "Pasted \(parts.joined(separator: ", "))"
  }
}
