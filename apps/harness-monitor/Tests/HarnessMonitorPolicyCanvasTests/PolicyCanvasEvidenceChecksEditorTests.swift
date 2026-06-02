import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

/// Phase 8: an `evidence_check` node exposes a full checks-array editor, not a
/// single field picker. Check order is the engine's failure priority (the first
/// failing check sets the reason code), so add / remove / reorder are the
/// authoring controls for the reason codes that downstream fan-in branches
/// route on. Each mutation lands as one undo step through the policy-kind funnel.
@Suite("Policy canvas evidence checks editor")
@MainActor
struct PolicyCanvasEvidenceChecksEditorTests {
  private func evidenceCanvas() -> (PolicyCanvasViewModel, String) {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    viewModel.createNode(kind: .evidenceCheck, at: CGPoint(x: 240, y: 120))
    let nodeID = viewModel.nodes.last?.id ?? ""
    viewModel.select(.node(nodeID))
    return (viewModel, nodeID)
  }

  @Test("add evidence check appends a check and undo restores the prior count")
  func addEvidenceCheckAppendsAndUndoes() throws {
    let (viewModel, nodeID) = evidenceCanvas()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let before = try #require(viewModel.node(nodeID)?.policyKind?.checks.count)

    viewModel.addSelectedEvidenceCheck()

    #expect(viewModel.node(nodeID)?.policyKind?.checks.count == before + 1)
    #expect(undoManager.canUndo)

    undoManager.undo()
    #expect(viewModel.node(nodeID)?.policyKind?.checks.count == before)
  }

  @Test("remove evidence check drops it but never empties the array")
  func removeEvidenceCheckKeepsAtLeastOne() throws {
    let (viewModel, nodeID) = evidenceCanvas()
    viewModel.addSelectedEvidenceCheck()
    #expect(viewModel.node(nodeID)?.policyKind?.checks.count == 2)

    viewModel.removeSelectedEvidenceCheck(at: 0)
    #expect(viewModel.node(nodeID)?.policyKind?.checks.count == 1)

    // The last check cannot be removed: an evidence_check with zero checks
    // would pass everything, stripping the node of its meaning.
    viewModel.removeSelectedEvidenceCheck(at: 0)
    #expect(viewModel.node(nodeID)?.policyKind?.checks.count == 1)
  }

  @Test("reorder evidence check changes failure priority and undo restores order")
  func reorderEvidenceCheckChangesPriority() throws {
    let (viewModel, nodeID) = evidenceCanvas()
    viewModel.commitSelectedEvidenceCheckField(.checksGreen, at: 0)
    viewModel.addSelectedEvidenceCheck()
    viewModel.commitSelectedEvidenceCheckField(.protectedPathTouched, at: 1)
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    viewModel.moveSelectedEvidenceCheck(from: 1, to: 0)

    #expect(
      viewModel.node(nodeID)?.policyKind?.checks.map(\.field)
        == [.protectedPathTouched, .checksGreen]
    )

    undoManager.undo()
    #expect(
      viewModel.node(nodeID)?.policyKind?.checks.map(\.field)
        == [.checksGreen, .protectedPathTouched]
    )
  }

  @Test("editing a check field, predicate, and fail reason code round-trips on export")
  func editEvidenceCheckRoundTrips() throws {
    let (viewModel, nodeID) = evidenceCanvas()

    viewModel.commitSelectedEvidenceCheckField(.protectedPathTouched, at: 0)
    viewModel.commitSelectedEvidenceCheckPredicate(.isFalse, at: 0)
    viewModel.commitSelectedEvidenceCheckFailReasonCode(
      PolicyCanvasReasonCode.protectedPathTouched,
      at: 0
    )

    let exported = viewModel.exportDocument()
    let check = try #require(exported.nodes.first { $0.id == nodeID }?.kind.checks.first)
    #expect(check.field == .protectedPathTouched)
    #expect(check.pass.predicate == .isFalse)
    #expect(check.failReasonCode == PolicyCanvasReasonCode.protectedPathTouched)
  }

  @Test("a fail reason code edit no-ops when the value is unchanged")
  func failReasonCodeNoOpWhenUnchanged() throws {
    let (viewModel, nodeID) = evidenceCanvas()
    let current = try #require(viewModel.node(nodeID)?.policyKind?.checks.first?.failReasonCode)
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    viewModel.commitSelectedEvidenceCheckFailReasonCode(current, at: 0)

    #expect(!undoManager.canUndo)
  }
}
