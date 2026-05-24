import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Wave 4J P07 rename tests. The funnel records one undo step per commit
/// (Enter or focus-lost), not per keystroke. Inverse restores the prior
/// title.
@Suite("Policy canvas rename node")
@MainActor
struct PolicyCanvasRenameNodeTests {
  @Test("renameNode writes the new title onto the target")
  func renameWritesTitle() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"

    viewModel.renameNode(nodeID, to: "Risk classifier")

    #expect(viewModel.node(nodeID)?.title == "Risk classifier")
  }

  @Test("renameNode is a no-op when the new title matches the current")
  func renameNoOpWhenUnchanged() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    let original = viewModel.node(nodeID)?.title ?? ""

    viewModel.renameNode(nodeID, to: original)

    #expect(!undoManager.canUndo)
  }

  @Test("renameNode is undoable")
  func renameIsUndoable() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    let originalTitle = viewModel.node(nodeID)?.title ?? ""

    viewModel.renameNode(nodeID, to: "Risk classifier")
    #expect(viewModel.node(nodeID)?.title == "Risk classifier")

    undoManager.undo()

    #expect(viewModel.node(nodeID)?.title == originalTitle)
  }

  @Test("renameNode is redoable")
  func renameIsRedoable() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"

    viewModel.renameNode(nodeID, to: "Risk classifier")
    undoManager.undo()
    undoManager.redo()

    #expect(viewModel.node(nodeID)?.title == "Risk classifier")
  }

  @Test("renameNode marks documentDirty")
  func renameMarksDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    let nodeID = "risk-score"

    viewModel.renameNode(nodeID, to: "Risk classifier")

    #expect(viewModel.documentDirty)
  }

  @Test("renameNode on a missing id is a safe no-op")
  func renameMissingIDIsSafe() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeCountBefore = viewModel.nodes.count

    viewModel.renameNode("does-not-exist", to: "Nope")

    #expect(viewModel.nodes.count == nodeCountBefore)
  }

  @Test("Sequential renames each become a separate undo step")
  func sequentialRenamesAreSeparateUndoSteps() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    let originalTitle = viewModel.node(nodeID)?.title ?? ""

    undoManager.beginUndoGrouping()
    viewModel.renameNode(nodeID, to: "Pass 1")
    undoManager.endUndoGrouping()

    undoManager.beginUndoGrouping()
    viewModel.renameNode(nodeID, to: "Pass 2")
    undoManager.endUndoGrouping()

    #expect(viewModel.node(nodeID)?.title == "Pass 2")

    undoManager.undo()
    #expect(viewModel.node(nodeID)?.title == "Pass 1")

    undoManager.undo()
    #expect(viewModel.node(nodeID)?.title == originalTitle)
  }

  @Test("renameNode preserves kind, group, and ports")
  func renamePreservesStructure() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    let originalKind = viewModel.node(nodeID)?.kind
    let originalGroup = viewModel.node(nodeID)?.groupID
    let originalInputs = viewModel.node(nodeID)?.inputPorts.map(\.id)
    let originalOutputs = viewModel.node(nodeID)?.outputPorts.map(\.id)

    viewModel.renameNode(nodeID, to: "Risk classifier")

    #expect(viewModel.node(nodeID)?.kind == originalKind)
    #expect(viewModel.node(nodeID)?.groupID == originalGroup)
    #expect(viewModel.node(nodeID)?.inputPorts.map(\.id) == originalInputs)
    #expect(viewModel.node(nodeID)?.outputPorts.map(\.id) == originalOutputs)
  }
}
