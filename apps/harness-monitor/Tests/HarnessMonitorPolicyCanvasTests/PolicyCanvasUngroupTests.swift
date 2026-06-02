import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Wave 4J P06 ungroup tests. The "Remove from group" command detaches the
/// node from its container; undo re-attaches. Group itself is untouched
/// (different from `deleteGroup` which removes the container).
@Suite("Policy canvas ungroup")
@MainActor
struct PolicyCanvasUngroupTests {
  @Test("removeNodeFromGroup clears the node's groupID")
  func removeFromGroupClearsGroupID() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    #expect(viewModel.node(nodeID)?.groupID == "group-evaluation")

    viewModel.removeNodeFromGroup(nodeID)

    #expect(viewModel.node(nodeID)?.groupID == nil)
  }

  @Test("removeNodeFromGroup leaves the group itself intact")
  func removeFromGroupKeepsContainer() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"

    viewModel.removeNodeFromGroup("risk-score")

    #expect(viewModel.group(groupID) != nil)
    // Other members untouched.
    #expect(viewModel.node("review-gate")?.groupID == groupID)
    #expect(viewModel.node("context-map")?.groupID == groupID)
  }

  @Test("removeNodeFromGroup on a group-less node is a no-op")
  func removeFromGroupNoOpForUngrouped() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "policy-source"
    if let index = viewModel.nodes.firstIndex(where: { $0.id == nodeID }) {
      viewModel.nodes[index].groupID = nil
    }
    viewModel.documentDirty = false

    viewModel.removeNodeFromGroup(nodeID)

    #expect(!viewModel.documentDirty)
  }

  @Test("removeNodeFromGroup is undoable")
  func removeFromGroupIsUndoable() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    let originalGroupID = viewModel.node(nodeID)?.groupID

    viewModel.removeNodeFromGroup(nodeID)
    #expect(viewModel.node(nodeID)?.groupID == nil)

    undoManager.undo()

    #expect(viewModel.node(nodeID)?.groupID == originalGroupID)
  }

  @Test("removeNodeFromGroup marks documentDirty")
  func removeFromGroupMarksDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false

    viewModel.removeNodeFromGroup("risk-score")

    #expect(viewModel.documentDirty)
  }

  @Test("Undo of removeNodeFromGroup restores the prior group membership")
  func undoRestoresGroupMembership() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    let originalGroupID = viewModel.node(nodeID)?.groupID

    viewModel.removeNodeFromGroup(nodeID)
    undoManager.undo()
    undoManager.redo()

    // After redo, ungrouped again.
    #expect(viewModel.node(nodeID)?.groupID == nil)

    undoManager.undo()
    // Original membership restored.
    #expect(viewModel.node(nodeID)?.groupID == originalGroupID)
  }

  @Test("removeNodeFromGroup reconciles the surviving group's frame")
  func removeFromGroupReconcilesFrame() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    let frameBefore = viewModel.group(groupID)?.frame

    viewModel.removeNodeFromGroup("risk-score")

    // Frame should re-fit around the remaining members.
    let frameAfter = viewModel.group(groupID)?.frame
    #expect(frameAfter != nil)
    #expect(frameBefore != frameAfter)
  }
}
