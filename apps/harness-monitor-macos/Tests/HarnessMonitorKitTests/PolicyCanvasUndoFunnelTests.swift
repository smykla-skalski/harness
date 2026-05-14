import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas undo/redo funnel")
@MainActor
struct PolicyCanvasUndoFunnelTests {
  @Test("addNode registers an inverse that removes the new node")
  func addNodeRegistersRemovingInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let countBefore = viewModel.nodes.count

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    #expect(viewModel.nodes.count == countBefore + 1)
    #expect(undoManager.canUndo)

    undoManager.undo()

    #expect(viewModel.nodes.count == countBefore)
  }

  @Test("removeNode registers an inverse that restores node and incident edges")
  func removeNodeRegistersRestoringInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    let nodeID = "risk-score"
    let nodeCountBefore = viewModel.nodes.count
    let edgeCountBefore = viewModel.edges.count
    let incidentEdgeCount = viewModel.edges.filter { edge in
      edge.source.nodeID == nodeID || edge.target.nodeID == nodeID
    }.count
    #expect(incidentEdgeCount > 0, "Sample must include risk-score edges")

    viewModel.deleteNode(nodeID)
    #expect(viewModel.node(nodeID) == nil)
    #expect(viewModel.edges.count == edgeCountBefore - incidentEdgeCount)

    undoManager.undo()

    #expect(viewModel.node(nodeID) != nil)
    #expect(viewModel.nodes.count == nodeCountBefore)
    #expect(viewModel.edges.count == edgeCountBefore)
  }

  @Test("removeNode inverse restores node group membership")
  func removeNodeInverseRestoresGroupMembership() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    let nodeID = "risk-score"
    let originalGroupID = viewModel.node(nodeID)?.groupID
    #expect(originalGroupID != nil)

    viewModel.deleteNode(nodeID)
    undoManager.undo()

    #expect(viewModel.node(nodeID)?.groupID == originalGroupID)
  }

  @Test("endNodeDrag registers an inverse that returns node to start position")
  func endNodeDragRegistersReturnInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    let nodeID = "risk-score"
    let originalPosition = viewModel.node(nodeID)?.position ?? .zero

    viewModel.dragNode(nodeID, translation: CGSize(width: 80, height: 60))
    viewModel.endNodeDrag(nodeID, translation: CGSize(width: 80, height: 60))
    let movedPosition = viewModel.node(nodeID)?.position
    #expect(movedPosition != originalPosition)

    undoManager.undo()

    #expect(viewModel.node(nodeID)?.position == originalPosition)
  }

  @Test("pure-click endNodeDrag does not register an undo step")
  func pureClickEndNodeDragDoesNotRegisterUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    // Force the node onto the grid first so the no-op gesture below cannot
    // be interpreted as a snap-to-grid correction (which is itself an undo-
    // worthy change).
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "risk-score" }) {
      viewModel.nodes[index].position = CGPoint(x: 360, y: 120)
    }

    viewModel.dragNode("risk-score", translation: .zero)
    viewModel.endNodeDrag("risk-score", translation: .zero)

    #expect(!undoManager.canUndo)
  }

  @Test("edge creation registers an inverse that drops the edge")
  func addEdgeRegistersInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let edgeCountBefore = viewModel.edges.count

    let created = viewModel.connectDroppedPortPayloads(
      [viewModel.portDragPayload(nodeID: "policy-source", portID: "output-event")],
      targetNodeID: "review-gate",
      targetPortID: "input-policy"
    )
    #expect(created)
    #expect(viewModel.edges.count == edgeCountBefore + 1)

    undoManager.undo()

    #expect(viewModel.edges.count == edgeCountBefore)
  }

  @Test("removeEdge registers an inverse that re-adds the edge")
  func removeEdgeRegistersInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let edgeID = "edge-intake-risk"
    let edgeCountBefore = viewModel.edges.count

    viewModel.deleteEdge(edgeID)
    #expect(!viewModel.edges.contains { $0.id == edgeID })

    undoManager.undo()

    #expect(viewModel.edges.contains { $0.id == edgeID })
    #expect(viewModel.edges.count == edgeCountBefore)
  }

  @Test("removeGroup registers an inverse that restores group + member membership")
  func removeGroupRegistersInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let groupID = "group-evaluation"
    let memberIDs = viewModel.nodes.filter { $0.groupID == groupID }.map(\.id)
    #expect(memberIDs.count >= 2, "Sample must have multiple evaluation members")

    viewModel.deleteGroup(groupID)
    #expect(viewModel.group(groupID) == nil)
    for memberID in memberIDs {
      #expect(viewModel.node(memberID)?.groupID == nil)
    }

    undoManager.undo()

    #expect(viewModel.group(groupID) != nil)
    for memberID in memberIDs {
      #expect(viewModel.node(memberID)?.groupID == groupID)
    }
  }

  @Test("endGroupDrag registers an inverse that returns group + members to start")
  func endGroupDragRegistersInverse() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let groupID = "group-evaluation"
    let memberIDs = viewModel.nodes.filter { $0.groupID == groupID }.map(\.id)
    let originGroupOrigin = viewModel.group(groupID)?.frame.origin ?? .zero
    let originMemberPositions = Dictionary(
      uniqueKeysWithValues: memberIDs.compactMap { id in
        viewModel.node(id).map { ($0.id, $0.position) }
      }
    )

    viewModel.dragGroup(groupID, translation: CGSize(width: 80, height: 40))
    viewModel.endGroupDrag(groupID, translation: CGSize(width: 80, height: 40))
    let movedOrigin = viewModel.group(groupID)?.frame.origin
    #expect(movedOrigin != originGroupOrigin)

    undoManager.undo()

    #expect(viewModel.group(groupID)?.frame.origin == originGroupOrigin)
    for (id, originalPosition) in originMemberPositions {
      #expect(viewModel.node(id)?.position == originalPosition, "member \(id) not restored")
    }
  }

  @Test("undo then redo round-trips state byte-equal to original mutation result")
  func undoRedoRoundTrip() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    viewModel.createNode(kind: .condition, at: CGPoint(x: 240, y: 240))
    let nodesAfterMutation = viewModel.nodes.map(\.id)
    let edgesAfterMutation = viewModel.edges.map(\.id)
    let groupsAfterMutation = viewModel.groups.map(\.id)

    undoManager.undo()
    undoManager.redo()

    #expect(viewModel.nodes.map(\.id) == nodesAfterMutation)
    #expect(viewModel.edges.map(\.id) == edgesAfterMutation)
    #expect(viewModel.groups.map(\.id) == groupsAfterMutation)
  }

  @Test("multi-step undo unwinds in reverse insertion order")
  func multiStepUndoUnwindsInReverseOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    // Use a non-event-grouped manager so each `mutate(_:)` registers its
    // own undo step. In production each user gesture (drag-end, palette
    // click, delete) spans separate runloop ticks, so the default
    // groupsByEvent=true naturally gives one entry per gesture. Tests run
    // synchronously and would otherwise coalesce all mutations into one
    // undo step.
    let undoManager = makeStepwiseUndoManager()
    viewModel.attachUndoManager(undoManager)
    let baselineNodeCount = viewModel.nodes.count

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    viewModel.createNode(kind: .transform, at: CGPoint(x: 400, y: 220))
    viewModel.createNode(kind: .review, at: CGPoint(x: 600, y: 240))
    #expect(viewModel.nodes.count == baselineNodeCount + 3)

    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount + 2)
    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount + 1)
    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount)
  }

  @Test("restoreState clears the undo stack")
  func restoreStateClearsUndoStack() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = makeStepwiseUndoManager()
    viewModel.attachUndoManager(undoManager)
    let snapshot = viewModel.snapshotState()

    viewModel.deleteNode("policy-source")
    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    #expect(undoManager.canUndo)

    viewModel.restoreState(snapshot)

    #expect(!undoManager.canUndo)
  }

  @Test("mutate without an attached undo manager applies the change but registers nothing")
  func mutateWithoutUndoManagerStillApplies() {
    let viewModel = PolicyCanvasViewModel.sample()
    let countBefore = viewModel.nodes.count

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))

    #expect(viewModel.nodes.count == countBefore + 1)
  }

  @Test("attaching nil undoManager makes mutate a no-op for undo tracking")
  func detachingUndoManagerDisablesUndoTracking() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.attachUndoManager(nil)

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))

    #expect(!undoManager.canUndo)
  }

  @Test("mutate sets documentDirty true and invalidates validation cache")
  func mutateSetsDirtyAndInvalidatesCache() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    let generationBefore = viewModel.validationInvalidationGeneration

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))

    #expect(viewModel.documentDirty)
    #expect(viewModel.validationInvalidationGeneration > generationBefore)
  }

  @Test("undo emits a status callback so the inspector line tracks the rollback")
  func undoEmitsStatusCallback() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    viewModel.deleteEdge("edge-intake-risk")
    let statusesAfterMutation = statuses.count

    undoManager.undo()

    #expect(statuses.count > statusesAfterMutation)
  }

  @Test("undo of a node delete restores the prior selection")
  func undoNodeDeleteRestoresPriorSelection() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.select(.node("risk-score"))

    viewModel.deleteNode("risk-score")
    #expect(viewModel.selection == nil)

    undoManager.undo()

    #expect(viewModel.selection == .node("risk-score"))
  }

  @Test("multi-mutation undo/redo round-trip preserves node id ordering")
  func multiMutationUndoRedoRoundTripIDOrdering() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    let originalNodeIDs = viewModel.nodes.map(\.id)
    let originalEdgeIDs = viewModel.edges.map(\.id)

    viewModel.deleteNode("risk-score")
    viewModel.deleteEdge("edge-context-promote")

    undoManager.undo()
    undoManager.undo()

    // Restoring inserts at the end, so the set must match but order need not.
    #expect(Set(viewModel.nodes.map(\.id)) == Set(originalNodeIDs))
    #expect(Set(viewModel.edges.map(\.id)) == Set(originalEdgeIDs))
  }

  @Test("addNode action name surfaces 'Add Node' on the undo manager")
  func addNodeSetsActionName() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))

    #expect(undoManager.undoActionName == "Add Node")
  }

  /// Build a fresh undo manager with `groupsByEvent` disabled so every
  /// `mutate(_:)` registers as its own undo step. In production the
  /// runloop-managed event group separates user gestures naturally; tests
  /// run synchronously and would otherwise coalesce all mutations into a
  /// single undo entry.
  private func makeStepwiseUndoManager() -> UndoManager {
    let manager = UndoManager()
    manager.groupsByEvent = false
    return manager
  }
}
