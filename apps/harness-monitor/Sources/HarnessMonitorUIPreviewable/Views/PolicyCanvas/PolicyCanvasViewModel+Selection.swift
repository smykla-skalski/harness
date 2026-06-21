import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  var selectedNode: PolicyCanvasNode? {
    guard case .node(let id) = selection else {
      return nil
    }
    return node(id)
  }

  var selectedGroup: PolicyCanvasGroup? {
    guard case .group(let id) = selection else {
      return nil
    }
    return group(id)
  }

  var selectedEdge: PolicyCanvasEdge? {
    guard case .edge(let id) = selection else {
      return nil
    }
    return edges.first { $0.id == id }
  }

  var selectedTitle: String {
    if let selectedNode {
      return selectedNode.title
    }
    if let selectedGroup {
      return selectedGroup.title
    }
    if let selectedEdge {
      return selectedEdge.label
    }
    return "Canvas"
  }

  var policySummary: String {
    "\(nodes.count) nodes - \(edges.count) edges - \(groups.count) groups"
  }
}
