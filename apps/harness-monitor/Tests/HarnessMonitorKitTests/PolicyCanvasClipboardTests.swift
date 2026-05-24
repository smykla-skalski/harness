import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Wave 4J P04 clipboard tests. Covers copy/paste/duplicate, plus the
/// reversibility contract (undo round-trips paste and duplicate).
@Suite("Policy canvas clipboard")
@MainActor
struct PolicyCanvasClipboardTests {
  @Test("Copy with no selection is a no-op")
  func copyWithNoSelectionIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)
    let copied = viewModel.copySelectionToClipboard()
    #expect(!copied)
    #expect(viewModel.clipboard == nil)
  }

  @Test("Copy of a single node populates clipboard with just that node")
  func copySingleNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    let copied = viewModel.copySelectionToClipboard()

    #expect(copied)
    let clipboard = viewModel.clipboard
    #expect(clipboard != nil)
    #expect(clipboard?.nodes.map(\.id) == ["policy-source"])
    #expect(clipboard?.edges.isEmpty == true)
    #expect(clipboard?.groups.isEmpty == true)
  }

  @Test("Copy drops edges crossing the selection boundary")
  func copyDropsBoundaryEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.edge("edge-intake-risk"))

    viewModel.copySelectionToClipboard()

    // edge-intake-risk targets risk-score, which is NOT in the selection;
    // the edge has to be dropped to avoid a stranded paste.
    let clipboard = viewModel.clipboard
    #expect(clipboard?.edges.isEmpty == true)
  }

  @Test("Copy keeps edges whose endpoints are both selected")
  func copyKeepsInteriorEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.extendSelection(.edge("edge-intake-risk"))

    viewModel.copySelectionToClipboard()

    let clipboard = viewModel.clipboard
    #expect(clipboard?.edges.map(\.id) == ["edge-intake-risk"])
  }

  @Test("Paste with empty clipboard is a no-op")
  func pasteEmptyClipboardIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeCountBefore = viewModel.nodes.count

    let pasted = viewModel.pasteFromClipboard()

    #expect(!pasted)
    #expect(viewModel.nodes.count == nodeCountBefore)
  }

  @Test("Paste of a single node inserts a new id with a 20pt offset")
  func pasteSingleNodeOffsets() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    let originalPosition = viewModel.node("policy-source")?.position ?? .zero
    viewModel.copySelectionToClipboard()
    let countBefore = viewModel.nodes.count

    let pasted = viewModel.pasteFromClipboard()

    #expect(pasted)
    #expect(viewModel.nodes.count == countBefore + 1)
    // The original node still exists; the paste adds a fresh one with a
    // different id.
    let originalStillExists = viewModel.nodes.contains { $0.id == "policy-source" }
    #expect(originalStillExists)
    // Find the new node — the one not equal to the original id but
    // sharing the kind.
    let cloned = viewModel.nodes.first { $0.id != "policy-source" && $0.kind == .source }
    #expect(cloned != nil)
    // After snap-to-grid the offset is at least the configured 20pt step.
    #expect(cloned?.position.x ?? 0 >= originalPosition.x + 20)
    #expect(cloned?.position.y ?? 0 >= originalPosition.y + 20)
  }

  @Test("Paste makes the new clones the selection")
  func pasteSelectsClones() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.copySelectionToClipboard()

    viewModel.pasteFromClipboard()

    // Primary should now be a new node id, not policy-source.
    if case .node(let id) = viewModel.selection {
      #expect(id != "policy-source")
    } else {
      Issue.record("expected paste to select the cloned node")
    }
  }

  @Test("Paste interior edge rewires endpoints to cloned node ids")
  func pasteRewiresInteriorEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.extendSelection(.edge("edge-intake-risk"))
    viewModel.copySelectionToClipboard()
    let edgeCountBefore = viewModel.edges.count

    viewModel.pasteFromClipboard()

    #expect(viewModel.edges.count == edgeCountBefore + 1)
    // The cloned edge should reference cloned node ids, not the originals.
    let cloned = viewModel.edges.first {
      $0.id != "edge-intake-risk"
        && $0.source.nodeID != "policy-source"
        && $0.target.nodeID != "risk-score"
    }
    #expect(cloned != nil)
    let liveNodeIDs = Set(viewModel.nodes.map(\.id))
    #expect(liveNodeIDs.contains(cloned?.source.nodeID ?? ""))
    #expect(liveNodeIDs.contains(cloned?.target.nodeID ?? ""))
  }

  @Test("Cmd+D duplicate clones without consuming the clipboard")
  func duplicatePreservesClipboard() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.copySelectionToClipboard()
    let bufferedNodeID = viewModel.clipboard?.nodes.first?.id

    let duplicated = viewModel.duplicateSelection()

    #expect(duplicated)
    // Clipboard untouched — Cmd+V on the freshly-duplicated selection still
    // pastes the originally-copied node.
    #expect(viewModel.clipboard?.nodes.first?.id == bufferedNodeID)
  }

  @Test("Paste is a single undoable step (Cmd+Z removes everything)")
  func pasteUndoesAsOneStep() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    viewModel.extendSelection(.edge("edge-intake-risk"))
    viewModel.copySelectionToClipboard()
    let nodeCountBefore = viewModel.nodes.count
    let edgeCountBefore = viewModel.edges.count

    viewModel.pasteFromClipboard()
    #expect(viewModel.nodes.count == nodeCountBefore + 2)
    #expect(viewModel.edges.count == edgeCountBefore + 1)

    undoManager.undo()

    #expect(viewModel.nodes.count == nodeCountBefore)
    #expect(viewModel.edges.count == edgeCountBefore)
  }

  @Test("Duplicate is a single undoable step")
  func duplicateUndoesAsOneStep() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("policy-source"))
    viewModel.extendSelection(.node("risk-score"))
    let nodeCountBefore = viewModel.nodes.count

    viewModel.duplicateSelection()
    #expect(viewModel.nodes.count == nodeCountBefore + 2)

    undoManager.undo()
    #expect(viewModel.nodes.count == nodeCountBefore)
  }

  @Test("Paste of a copied group re-creates the group with a fresh id")
  func pasteGroupGetsFreshID() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.group("group-evaluation"))
    viewModel.copySelectionToClipboard()
    let groupCountBefore = viewModel.groups.count

    viewModel.pasteFromClipboard()

    #expect(viewModel.groups.count == groupCountBefore + 1)
    let added = viewModel.groups.first { $0.id != "group-evaluation" && $0.tone == .evaluation }
    #expect(added != nil)
  }

  @Test("Paste sets documentDirty true (graph mutation)")
  func pasteMarksDocumentDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.copySelectionToClipboard()
    viewModel.documentDirty = false

    viewModel.pasteFromClipboard()

    #expect(viewModel.documentDirty)
  }

  @Test("Duplicate sets documentDirty true (graph mutation)")
  func duplicateMarksDocumentDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    viewModel.documentDirty = false

    viewModel.duplicateSelection()

    #expect(viewModel.documentDirty)
  }

  @Test("Redo of an undone paste restores the cloned set")
  func redoPasteRestoresClones() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("policy-source"))
    viewModel.copySelectionToClipboard()

    viewModel.pasteFromClipboard()
    let nodeIDsAfterPaste = viewModel.nodes.map(\.id)

    undoManager.undo()
    undoManager.redo()

    // ID set after redo must match the ID set right after paste.
    #expect(Set(viewModel.nodes.map(\.id)) == Set(nodeIDsAfterPaste))
  }
}
