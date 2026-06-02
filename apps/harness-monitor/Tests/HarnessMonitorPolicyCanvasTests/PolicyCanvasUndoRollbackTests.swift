import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Covers the rollback / clear-undo-stack / orphan-edge corner cases that
/// sit at the seam between the wave 3H mutate funnel and an unrelated
/// daemon-driven document republish. The vanilla register-inverse +
/// undo/redo contracts live in `PolicyCanvasUndoFunnelTests`.
@Suite("Policy canvas undo rollback + cross-republish")
@MainActor
struct PolicyCanvasUndoRollbackTests {
  @Test("restoreState clears the undo stack")
  func restoreStateClearsUndoStack() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)
    let snapshot = viewModel.snapshotState()

    stepwise(undoManager) {
      viewModel.deleteNode("policy-source")
    }
    stepwise(undoManager) {
      viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    }
    #expect(undoManager.canUndo)

    viewModel.restoreState(snapshot)

    #expect(!undoManager.canUndo)
  }

  @Test("restoreState preserves undo actions registered by other targets")
  func restoreStatePreservesForeignUndoActions() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)
    let foreignTarget = NSObject()
    // Foreign action stands in for a text field elsewhere in the window
    // that has registered into the same window-scoped UndoManager. The
    // canvas's `clearUndoStack` must not touch this entry.
    stepwise(undoManager) {
      undoManager.registerUndo(withTarget: foreignTarget) { _ in }
    }
    stepwise(undoManager) {
      viewModel.deleteNode("policy-source")
    }
    let snapshot = viewModel.snapshotState()

    stepwise(undoManager) {
      viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    }

    viewModel.restoreState(snapshot)

    #expect(undoManager.canUndo, "Foreign action should survive clearUndoStack")
  }

  @Test("applyRestoreNode silently filters incident edges whose other end no longer exists")
  func applyRestoreNodeFiltersOrphanIncidentEdges() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)

    // Pick a node that participates in at least one edge so the undo
    // payload captures incident edges.
    let nodeID = "risk-score"
    let incidentEdges = viewModel.edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }
    #expect(incidentEdges.count >= 1, "Sample must include risk-score edges")
    // Identify the "other end" of one incident edge — the node that the
    // simulated remote republish will drop.
    let siblingNodeIDs = incidentEdges.compactMap { edge -> String? in
      let other = edge.source.nodeID == nodeID ? edge.target.nodeID : edge.source.nodeID
      return other == nodeID ? nil : other
    }
    guard let droppedSibling = siblingNodeIDs.first else {
      Issue.record("Could not find sibling node for orphan-filter setup")
      return
    }

    stepwise(undoManager) {
      viewModel.deleteNode(nodeID)
    }
    // Simulate the daemon republishing while the node was removed: the
    // sibling node gets dropped from the live graph. Undo will try to
    // re-insert the incident edge against the captured payload, but the
    // sibling no longer exists.
    viewModel.nodes.removeAll { $0.id == droppedSibling }

    let edgeCountBeforeUndo = viewModel.edges.count
    undoManager.undo()

    // Node is restored, but edges that referenced the dropped sibling
    // are silently filtered.
    #expect(viewModel.node(nodeID) != nil)
    let restoredEdges = viewModel.edges.count - edgeCountBeforeUndo
    let expectedSurvivors = incidentEdges.filter { edge in
      edge.source.nodeID != droppedSibling && edge.target.nodeID != droppedSibling
    }.count
    #expect(restoredEdges == expectedSurvivors)
    // None of the live edges may reference the dropped sibling.
    #expect(
      !viewModel.edges.contains(where: { edge in
        edge.source.nodeID == droppedSibling || edge.target.nodeID == droppedSibling
      })
    )
  }

  @Test("multi-step mutate + undo + redo round-trips after dropping inner grouping")
  func multiStepMutateUndoRedoRoundTrip() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)
    let originalNodes = viewModel.nodes.map(\.id)

    stepwise(undoManager) {
      viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    }
    stepwise(undoManager) {
      viewModel.createNode(kind: .transform, at: CGPoint(x: 400, y: 220))
    }
    let nodesAfterMutations = viewModel.nodes.map(\.id)

    undoManager.undo()
    undoManager.undo()
    #expect(viewModel.nodes.map(\.id) == originalNodes)

    undoManager.redo()
    undoManager.redo()
    #expect(viewModel.nodes.map(\.id) == nodesAfterMutations)
  }

  /// Build an undo manager that produces one undo step per
  /// `stepwise(_:_:)` block when used in synchronous test code. The
  /// default `groupsByEvent=true` mode opens an auto event group per
  /// runloop tick and nests every explicit `beginUndoGrouping` inside
  /// it; a single `undo()` then unwinds the whole event group. With
  /// `groupsByEvent=false`, each `beginUndoGrouping`/`endUndoGrouping`
  /// pair is its own top-level group, and `undo()` unwinds one at a
  /// time.
  private func stepwiseManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
  }

  /// Wrap a synchronous mutation in an explicit undo group so each
  /// `mutate(_:)` becomes its own undo step against a
  /// `stepwiseManager()`. In production each user gesture (drag-end,
  /// palette click, delete) lands on its own runloop tick, so the
  /// runtime event group naturally separates gestures into one undo
  /// step each.
  private func stepwise(_ manager: UndoManager, _ body: () -> Void) {
    manager.beginUndoGrouping()
    body()
    manager.endUndoGrouping()
  }
}
