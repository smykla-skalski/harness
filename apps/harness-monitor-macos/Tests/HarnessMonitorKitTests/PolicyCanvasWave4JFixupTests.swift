import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Locks the contract introduced by the Wave 4J power-edit fixup pass:
/// arrow-nudge over multi-select coalesces into one undo step, the
/// extended `moveNode` change shape carries auto-attached group membership
/// through inverse, `bulkAdd`/`bulkRemove` round-trip secondary selections,
/// and `Cmd+A` followed by Delete deletes the whole selection.
@Suite("Policy canvas Wave 4J fixup")
@MainActor
struct PolicyCanvasWave4JFixupTests {
  @Test("Arrow-nudge over multi-select collapses into one undo step")
  func nudgeMultiCollapsesOneUndoStep() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    // Detach group memberships so a node-only multi-select can be nudged
    // without group double-move.
    for index in viewModel.nodes.indices {
      viewModel.nodes[index].groupID = nil
    }
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.extendSelection(.node("review-gate"))
    let aBefore = viewModel.node("policy-source")?.position ?? .zero
    let bBefore = viewModel.node("risk-score")?.position ?? .zero
    let cBefore = viewModel.node("review-gate")?.position ?? .zero

    let moved = viewModel.nudgeSelection(by: CGSize(width: 4, height: 0))
    #expect(moved)
    #expect(viewModel.node("policy-source")?.position.x == aBefore.x + 4)
    #expect(viewModel.node("risk-score")?.position.x == bBefore.x + 4)
    #expect(viewModel.node("review-gate")?.position.x == cBefore.x + 4)

    // A single undo reverts every member of the multi-select.
    undoManager.undo()
    #expect(viewModel.node("policy-source")?.position == aBefore)
    #expect(viewModel.node("risk-score")?.position == bBefore)
    #expect(viewModel.node("review-gate")?.position == cBefore)
  }

  @Test("Move-node carries group membership across undo")
  func moveNodeReplaysGroupMembership() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "policy-source"
    let originalGroupID = viewModel.node(nodeID)?.groupID
    let originalPosition = viewModel.node(nodeID)?.position ?? .zero
    // End-drag sets `toGroupID = nil` so the apply path recomputes auto-
    // attach; pretend the move popped the node out of its group by
    // mutating directly first.
    let destination = CGPoint(x: 1500, y: 1500)  // far outside any group
    viewModel.mutate(
      .moveNode(
        id: nodeID,
        from: originalPosition,
        to: destination,
        fromGroupID: originalGroupID,
        toGroupID: nil
      )
    )
    // After the move the node may have lost or kept its membership
    // depending on auto-attach; what matters is that undo restores the
    // original `groupID`.
    undoManager.undo()
    #expect(viewModel.node(nodeID)?.position == originalPosition)
    #expect(viewModel.node(nodeID)?.groupID == originalGroupID)
  }

  @Test("BulkAdd inverse restores secondary selections at paste time")
  func bulkAddInverseRestoresSecondaries() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    let priorSecondaries = viewModel.secondarySelections

    viewModel.copySelectionToClipboard()
    viewModel.pasteFromClipboard()
    // After paste, the cloned set becomes the new selection.
    #expect(viewModel.selection != .node("policy-source"))

    undoManager.undo()
    // Primary is restored to the pre-paste primary.
    #expect(viewModel.selection == .node("policy-source"))
    // Secondaries are restored: the shift-clicked risk-score is back.
    #expect(viewModel.secondarySelections == priorSecondaries)
  }

  @Test("Cmd+A then Delete removes the entire multi-selection")
  func selectAllDeleteRemovesEverySelected() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.selectAll()
    #expect(!viewModel.secondarySelections.isEmpty)

    let request = viewModel.deleteSelectedComponent()
    // Multi-delete bypasses the confirmation dialog and routes through
    // bulkRemove directly; the caller therefore receives nil.
    #expect(request == nil)
    #expect(viewModel.nodes.isEmpty)
    #expect(viewModel.edges.isEmpty)
    #expect(viewModel.groups.isEmpty)

    // Single undo restores everything.
    undoManager.undo()
    #expect(!viewModel.nodes.isEmpty)
    #expect(!viewModel.edges.isEmpty)
    #expect(!viewModel.groups.isEmpty)
  }

  @Test("Right-click Duplicate on a multi-select preserves the secondaries")
  func rightClickDuplicatePreservesMultiSelect() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    let nodeCountBefore = viewModel.nodes.count

    // The right-click branch only promotes-to-primary when the clicked
    // node is NOT already in the selection; verify the multi-select
    // case duplicates two nodes instead of one.
    #expect(viewModel.isSelected(.node("policy-source")))
    viewModel.duplicateSelection()

    #expect(viewModel.nodes.count == nodeCountBefore + 2)
  }

  @Test("Stable promotion picks the earliest secondary in model order")
  func stablePromotionFromSecondary() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("review-gate"))
    viewModel.extendSelection(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    // Shift-click primary off; promotion should pick policy-source (first
    // in the sample data order) regardless of insertion sequence.
    viewModel.extendSelection(.node("review-gate"))
    #expect(viewModel.selection == .node("policy-source"))
  }

  @Test("BulkMove inverse restores both nodes and group members")
  func bulkMoveInverseRestoresEverything() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.group("group-evaluation"))
    let groupOriginBefore = viewModel.group("group-evaluation")?.frame.origin ?? .zero
    let memberPositionsBefore = viewModel.nodes
      .filter { $0.groupID == "group-evaluation" }
      .reduce(into: [String: CGPoint]()) { partial, node in
        partial[node.id] = node.position
      }

    viewModel.nudgeSelection(by: CGSize(width: 0, height: 12))
    #expect(viewModel.group("group-evaluation")?.frame.origin.y == groupOriginBefore.y + 12)

    undoManager.undo()

    #expect(viewModel.group("group-evaluation")?.frame.origin == groupOriginBefore)
    for (id, expected) in memberPositionsBefore {
      #expect(viewModel.node(id)?.position == expected)
    }
  }
}
