import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 4J P30 arrow-nudge tests. Routes through `.moveNode` / `.moveGroup`
/// via `mutate(_:)` so each nudge collapses to one undo step. Groups carry
/// member offsets along.
@Suite("Policy canvas arrow nudge")
@MainActor
struct PolicyCanvasArrowNudgeTests {
  @Test("Nudge with no selection is a safe no-op")
  func nudgeNoSelectionIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)

    let moved = viewModel.nudgeSelection(by: CGSize(width: 1, height: 0))

    #expect(!moved)
  }

  @Test("Nudge right by 1pt shifts the selected node by 1pt")
  func nudgeRightOnePoint() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))
    let original = viewModel.node(nodeID)?.position ?? .zero

    let moved = viewModel.nudgeSelection(by: CGSize(width: 1, height: 0))

    #expect(moved)
    #expect(viewModel.node(nodeID)?.position.x == original.x + 1)
    #expect(viewModel.node(nodeID)?.position.y == original.y)
  }

  @Test("Nudge down by 10pt (shift) shifts the selected node by 10pt")
  func nudgeShiftIsTenPoints() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))
    let original = viewModel.node(nodeID)?.position ?? .zero

    viewModel.nudgeSelection(by: CGSize(width: 0, height: 10))

    #expect(viewModel.node(nodeID)?.position.y == original.y + 10)
  }

  @Test("Nudge by grid step matches PolicyCanvasLayout.gridSize")
  func nudgeGridStep() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))
    let original = viewModel.node(nodeID)?.position ?? .zero
    let grid = PolicyCanvasLayout.gridSize

    viewModel.nudgeSelection(by: CGSize(width: grid, height: 0))

    #expect(viewModel.node(nodeID)?.position.x == original.x + grid)
  }

  @Test("Nudge is a single undoable step per direction")
  func nudgeUndoesAsOneStep() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let nodeID = "risk-score"
    viewModel.select(.node(nodeID))
    let original = viewModel.node(nodeID)?.position ?? .zero

    viewModel.nudgeSelection(by: CGSize(width: 10, height: 0))
    let movedPosition = viewModel.node(nodeID)?.position
    #expect(movedPosition?.x == original.x + 10)

    undoManager.undo()

    #expect(viewModel.node(nodeID)?.position == original)
  }

  @Test("Nudge of a multi-selection moves each member")
  func nudgeMultipleNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))
    // policy-source is in group-intake; pick a non-grouped target by
    // also extending to review-gate (group-evaluation) and confirming
    // both move when their groups are not selected together.
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "policy-source" }) {
      viewModel.nodes[index].groupID = nil
    }
    viewModel.extendSelection(.node("promote-release"))
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "promote-release" }) {
      viewModel.nodes[index].groupID = nil
    }
    let aBefore = viewModel.node("policy-source")?.position ?? .zero
    let bBefore = viewModel.node("promote-release")?.position ?? .zero

    viewModel.nudgeSelection(by: CGSize(width: 5, height: 0))

    #expect(viewModel.node("policy-source")?.position.x == aBefore.x + 5)
    #expect(viewModel.node("promote-release")?.position.x == bBefore.x + 5)
  }

  @Test("Nudge of a group moves group and its members by the same delta")
  func nudgeGroupMovesMembers() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    viewModel.select(.group(groupID))
    let groupBefore = viewModel.group(groupID)?.frame.origin ?? .zero
    let memberPositionsBefore = viewModel.nodes
      .filter { $0.groupID == groupID }
      .reduce(into: [String: CGPoint]()) { partial, node in
        partial[node.id] = node.position
      }

    viewModel.nudgeSelection(by: CGSize(width: 0, height: 20))

    let groupAfter = viewModel.group(groupID)?.frame.origin ?? .zero
    #expect(groupAfter.y == groupBefore.y + 20)
    for (id, before) in memberPositionsBefore {
      #expect(viewModel.node(id)?.position.y == before.y + 20)
    }
  }

  @Test("Nudging a node already inside a selected group doesn't double-move")
  func nudgeDoesNotDoubleMoveGroupedNode() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-evaluation"
    let nodeID = "risk-score"
    viewModel.select(.group(groupID))
    viewModel.extendSelection(.node(nodeID))
    let before = viewModel.node(nodeID)?.position ?? .zero

    viewModel.nudgeSelection(by: CGSize(width: 10, height: 0))

    // Group move carries the node along by 10pt; the standalone node
    // nudge must be suppressed so the total displacement is 10, not 20.
    #expect(viewModel.node(nodeID)?.position.x == before.x + 10)
  }

  @Test("Nudge marks documentDirty")
  func nudgeMarksDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("risk-score"))
    viewModel.documentDirty = false

    viewModel.nudgeSelection(by: CGSize(width: 1, height: 0))

    #expect(viewModel.documentDirty)
  }

  @Test("Nudge with zero delta is a no-op")
  func nudgeZeroDeltaIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))

    let moved = viewModel.nudgeSelection(by: .zero)

    #expect(!moved)
    #expect(!undoManager.canUndo)
  }

  @Test("Nudge of an edge-only selection is a safe no-op")
  func nudgeEdgeOnlyIsNoOp() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.edge("edge-intake-risk"))

    let moved = viewModel.nudgeSelection(by: CGSize(width: 1, height: 0))

    // No nodes or groups picked — there's nothing whose position to write.
    #expect(!moved)
  }
}
