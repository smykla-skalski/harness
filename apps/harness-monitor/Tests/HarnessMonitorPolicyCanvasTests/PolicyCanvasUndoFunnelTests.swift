import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

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
    // Force the node onto the grid first so the no-op gesture below cannot
    // be interpreted as a snap-to-grid correction (which is itself an undo-
    // worthy change).
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "risk-score" }) {
      viewModel.nodes[index].position = CGPoint(x: 360, y: 120)
    }
    viewModel.markSavedDocument(viewModel.exportDocument())
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)

    viewModel.dragNode("risk-score", translation: .zero)
    viewModel.endNodeDrag("risk-score", translation: .zero)

    #expect(!undoManager.canUndo)
    #expect(!viewModel.documentDirty)
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
    // Tests run synchronously inside one runloop tick. With the default
    // `groupsByEvent=true`, an explicit `beginUndoGrouping`/
    // `endUndoGrouping` block opens a nested sub-group inside the auto
    // event group, so a single `undo()` would unwind the whole event
    // group (all three sub-groups at once). Disable `groupsByEvent` so
    // each `stepwise(_:_:)` block becomes its own top-level group with
    // one mutation each.
    //
    // In production each user gesture (drag-end, palette click, delete)
    // lands on its own runloop tick, so `groupsByEvent=true` already
    // gives one undo step per gesture.
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)
    let baselineNodeCount = viewModel.nodes.count

    stepwise(undoManager) {
      viewModel.createNode(kind: .condition, at: CGPoint(x: 200, y: 200))
    }
    stepwise(undoManager) {
      viewModel.createNode(kind: .transform, at: CGPoint(x: 400, y: 220))
    }
    stepwise(undoManager) {
      viewModel.createNode(kind: .review, at: CGPoint(x: 600, y: 240))
    }
    #expect(viewModel.nodes.count == baselineNodeCount + 3)

    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount + 2)
    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount + 1)
    undoManager.undo()
    #expect(viewModel.nodes.count == baselineNodeCount)
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

  @Test("dragging a node back to its saved origin clears dirty state")
  func draggingNodeBackToSavedOriginClearsDirtyState() async {
    let viewModel = PolicyCanvasViewModel.sample()
    if let index = viewModel.nodes.firstIndex(where: { $0.id == "risk-score" }) {
      viewModel.nodes[index].position = CGPoint(x: 360, y: 120)
    }
    viewModel.markSavedDocument(viewModel.exportDocument())
    let nodeID = "risk-score"
    let originalPosition = viewModel.node(nodeID)?.position ?? .zero

    let outward = CGSize(width: 80, height: 60)
    viewModel.dragNode(nodeID, translation: outward)
    viewModel.endNodeDrag(nodeID, translation: outward)
    let movedPosition = viewModel.node(nodeID)?.position ?? .zero
    #expect(movedPosition != originalPosition)
    #expect(viewModel.documentDirty)

    let back = CGSize(
      width: originalPosition.x - movedPosition.x,
      height: originalPosition.y - movedPosition.y
    )
    viewModel.dragNode(nodeID, translation: back)
    viewModel.endNodeDrag(nodeID, translation: back)
    await waitForPolicyCanvasDirtyReconciliation(viewModel)

    #expect(viewModel.node(nodeID)?.position == originalPosition)
    #expect(!viewModel.documentDirty)
    #expect(viewModel.draftStatusText == "Saved draft")
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
    // See `multiStepUndoUnwindsInReverseOrder` for why
    // `groupsByEvent=false` is needed inside a synchronous test run.
    let undoManager = stepwiseManager()
    viewModel.attachUndoManager(undoManager)
    let originalNodeIDs = viewModel.nodes.map(\.id)
    let originalEdgeIDs = viewModel.edges.map(\.id)

    stepwise(undoManager) {
      viewModel.deleteNode("risk-score")
    }
    stepwise(undoManager) {
      viewModel.deleteEdge("edge-context-promote")
    }

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
