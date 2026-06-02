import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas delete operations")
@MainActor
struct PolicyCanvasDeleteTests {
  @Test("deleteNode removes node and cascades to incident edges")
  func deleteNodeCascadesEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    let incidentBefore = viewModel.edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }
    #expect(incidentBefore.count >= 1, "Sample must include risk-score edges")

    viewModel.deleteNode(nodeID)

    #expect(viewModel.node(nodeID) == nil)
    let incidentAfter = viewModel.edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }
    #expect(incidentAfter.isEmpty)
  }

  @Test("deleteEdge removes the edge only and leaves nodes intact")
  func deleteEdgeRemovesEdgeOnly() {
    let viewModel = PolicyCanvasViewModel.sample()
    let edgeID = "edge-intake-risk"
    let nodeCountBefore = viewModel.nodes.count
    let edgeCountBefore = viewModel.edges.count
    #expect(viewModel.edges.contains { $0.id == edgeID })

    viewModel.deleteEdge(edgeID)

    #expect(!viewModel.edges.contains { $0.id == edgeID })
    #expect(viewModel.edges.count == edgeCountBefore - 1)
    #expect(viewModel.nodes.count == nodeCountBefore)
  }

  @Test("deleteGroup ungroups members instead of cascading")
  func deleteGroupUngroupsMembers() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    let memberIDs = viewModel.nodes
      .filter { $0.groupID == groupID }
      .map(\.id)
    #expect(!memberIDs.isEmpty, "Sample must include evaluation members")

    viewModel.deleteGroup(groupID)

    #expect(viewModel.group(groupID) == nil)
    for memberID in memberIDs {
      let node = viewModel.node(memberID)
      #expect(node != nil)
      #expect(node?.groupID == nil)
    }
  }

  @Test("deleteNode clears selection when the deleted node was selected")
  func deleteNodeClearsSelectionWhenSelected() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))

    viewModel.deleteNode(nodeID)

    #expect(viewModel.selection == nil)
  }

  @Test("deleteNode keeps selection when a different node is selected")
  func deleteNodeKeepsForeignSelection() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    viewModel.deleteNode("risk-score")

    #expect(viewModel.selection == .node("policy-source"))
  }

  @Test("deleteEdge clears selection when the deleted edge was selected")
  func deleteEdgeClearsSelectionWhenSelected() {
    let viewModel = PolicyCanvasViewModel.sample()
    let edgeID = "edge-intake-risk"
    viewModel.select(.edge(edgeID))

    viewModel.deleteEdge(edgeID)

    #expect(viewModel.selection == nil)
  }

  @Test("deleteGroup clears selection when the deleted group was selected")
  func deleteGroupClearsSelectionWhenSelected() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    viewModel.select(.group(groupID))

    viewModel.deleteGroup(groupID)

    #expect(viewModel.selection == nil)
  }

  @Test("delete mutations set documentDirty to true")
  func deleteMutationsMarkDocumentDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false

    viewModel.deleteEdge("edge-intake-risk")

    #expect(viewModel.documentDirty)

    viewModel.documentDirty = false
    viewModel.deleteGroup("group-release")
    #expect(viewModel.documentDirty)

    viewModel.documentDirty = false
    viewModel.deleteNode("policy-source")
    #expect(viewModel.documentDirty)
  }

  @Test("delete mutations notify status with Deleted prefix")
  func deleteMutationsNotifyStatus() {
    let viewModel = PolicyCanvasViewModel.sample()
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    viewModel.deleteNode("policy-source")
    viewModel.deleteEdge("edge-risk-context")
    viewModel.deleteGroup("group-release")

    #expect(statuses.count == 3)
    for status in statuses {
      #expect(status.hasPrefix("Deleted"), "status=\(status)")
    }
  }

  @Test("deleteNode is a no-op when the id is unknown")
  func deleteUnknownNodeIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeCountBefore = viewModel.nodes.count
    let edgeCountBefore = viewModel.edges.count
    viewModel.documentDirty = false

    viewModel.deleteNode("does-not-exist")

    #expect(viewModel.nodes.count == nodeCountBefore)
    #expect(viewModel.edges.count == edgeCountBefore)
    #expect(!viewModel.documentDirty)
  }

  @Test("clearTransientGestureState wipes hover and drop highlights")
  func clearTransientGestureStateWipesHover() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setInputTargeted(true, nodeID: "review-gate", portID: "input-policy")
    viewModel.highlightedGroupID = "group-evaluation"

    viewModel.clearTransientGestureState()

    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }

  @Test("clearSelection drops selection and transient gesture state")
  func clearSelectionDropsSelectionAndTransient() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    viewModel.setInputTargeted(true, nodeID: "review-gate", portID: "input-policy")
    viewModel.highlightedGroupID = "group-evaluation"

    viewModel.clearSelection()

    #expect(viewModel.selection == nil)
    #expect(viewModel.highlightedInput == nil)
    #expect(viewModel.highlightedGroupID == nil)
  }
}
