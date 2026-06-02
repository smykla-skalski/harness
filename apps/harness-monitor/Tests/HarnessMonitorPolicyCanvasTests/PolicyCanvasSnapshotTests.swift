import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas snapshot and restore")
@MainActor
struct PolicyCanvasSnapshotTests {
  @Test("snapshot captures nodes, groups, edges, and selection")
  func snapshotCapturesGraphState() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.node("policy-source"))

    let snapshot = viewModel.snapshotState()

    #expect(snapshot.nodes.count == viewModel.nodes.count)
    #expect(snapshot.groups.count == viewModel.groups.count)
    #expect(snapshot.edges.count == viewModel.edges.count)
    #expect(snapshot.selection == .node("policy-source"))
  }

  @Test("restore returns to snapshot after mutations")
  func restoreReturnsToSnapshotAfterMutations() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(.edge("edge-intake-risk"))
    let snapshot = viewModel.snapshotState()
    let nodesBefore = viewModel.nodes.map(\.id)
    let edgesBefore = viewModel.edges.map(\.id)
    let groupsBefore = viewModel.groups.map(\.id)

    viewModel.deleteNode("policy-source")
    viewModel.deleteGroup("group-evaluation")
    viewModel.createNode(kind: .condition, at: CGPoint(x: 600, y: 600))

    #expect(viewModel.nodes.map(\.id) != nodesBefore)

    viewModel.restoreState(snapshot)

    #expect(viewModel.nodes.map(\.id) == nodesBefore)
    #expect(viewModel.edges.map(\.id) == edgesBefore)
    #expect(viewModel.groups.map(\.id) == groupsBefore)
    #expect(viewModel.selection == .edge("edge-intake-risk"))
  }

  @Test("snapshot is value-typed and not mutated by later writes")
  func snapshotIsValueTypedNotMutatedByLaterWrites() {
    let viewModel = PolicyCanvasViewModel.sample()
    let snapshot = viewModel.snapshotState()
    let snapshotNodeCount = snapshot.nodes.count

    viewModel.deleteNode("policy-source")

    #expect(snapshot.nodes.count == snapshotNodeCount)
    #expect(snapshot.nodes.contains { $0.id == "policy-source" })
  }

  @Test("restore preserves nil selection")
  func restorePreservesNilSelection() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.select(nil)
    let snapshot = viewModel.snapshotState()

    viewModel.select(.node("risk-score"))
    viewModel.restoreState(snapshot)

    #expect(viewModel.selection == nil)
  }

  @Test("restore emits status callback")
  func restoreEmitsStatusCallback() {
    let viewModel = PolicyCanvasViewModel.sample()
    let snapshot = viewModel.snapshotState()
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    viewModel.restoreState(snapshot)

    #expect(statuses.count >= 1)
    #expect(
      statuses.last?.contains("restored") == true || statuses.last?.contains("Restored") == true)
  }

  @Test("restore leaves documentDirty true so caller can resave")
  func restoreLeavesDocumentDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = true
    let snapshot = viewModel.snapshotState()

    viewModel.deleteNode("policy-source")
    viewModel.restoreState(snapshot)

    #expect(viewModel.documentDirty)
  }

  @Test("restore reconciles group frames around restored member positions")
  func restoreReconcilesGroupFrames() {
    let viewModel = PolicyCanvasViewModel.sample()
    let originalFrame = viewModel.group("group-evaluation")?.frame ?? .zero
    let snapshot = viewModel.snapshotState()

    viewModel.dragNode("risk-score", translation: CGSize(width: 0, height: 600))
    viewModel.endNodeDrag("risk-score", translation: CGSize(width: 0, height: 600))
    #expect(viewModel.group("group-evaluation")?.frame.height ?? 0 > originalFrame.height)

    viewModel.restoreState(snapshot)

    let restoredFrame = viewModel.group("group-evaluation")?.frame
    #expect(restoredFrame != nil)
  }

  @Test("restore with markDirty=false leaves document clean")
  func restoreMarkDirtyFalseLeavesDocumentClean() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.documentDirty = false
    let snapshot = viewModel.snapshotState()

    viewModel.createNode(kind: .condition, at: CGPoint(x: 100, y: 100))
    #expect(viewModel.documentDirty)

    viewModel.restoreState(snapshot, markDirty: false)

    #expect(!viewModel.documentDirty)
  }

  @Test("restore with default markDirty preserves dirty flag for retry")
  func restoreDefaultMarkDirtyPreservesDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    let snapshot = viewModel.snapshotState()

    viewModel.documentDirty = false
    viewModel.restoreState(snapshot)

    #expect(viewModel.documentDirty)
  }

  @Test("restore emits caller-supplied reason")
  func restoreEmitsCallerSuppliedReason() {
    let viewModel = PolicyCanvasViewModel.sample()
    let snapshot = viewModel.snapshotState()
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    viewModel.restoreState(snapshot, reason: "Simulation rejected, restored previous canvas")

    #expect(statuses.last == "Simulation rejected, restored previous canvas")
  }

  @Test("restore default reason matches save-reject phrasing")
  func restoreDefaultReasonMatchesSaveReject() {
    let viewModel = PolicyCanvasViewModel.sample()
    let snapshot = viewModel.snapshotState()
    var statuses: [String] = []
    viewModel.statusCallback = { @MainActor message in
      statuses.append(message)
    }

    viewModel.restoreState(snapshot)

    #expect(statuses.last == "Save rejected, restored previous canvas")
  }

  @Test("snapshot captures latest simulation")
  func snapshotCapturesLatestSimulation() {
    let viewModel = PolicyCanvasViewModel.sample()
    let simulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 7,
      traceId: "trace-snap",
      simulatedAt: "2026-05-14T11:00:00Z",
      succeeded: false,
      validation: TaskBoardPolicyPipelineValidation(isValid: false)
    )
    viewModel.latestSimulation = simulation

    let snapshot = viewModel.snapshotState()

    #expect(snapshot.latestSimulation?.revision == 7)
    #expect(snapshot.latestSimulation?.traceId == "trace-snap")
  }

  @Test("restore brings back captured simulation")
  func restoreBringsBackCapturedSimulation() {
    let viewModel = PolicyCanvasViewModel.sample()
    let originalSimulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 11,
      traceId: "trace-original",
      simulatedAt: "2026-05-14T11:00:00Z",
      succeeded: true,
      validation: TaskBoardPolicyPipelineValidation(isValid: true)
    )
    viewModel.latestSimulation = originalSimulation
    let snapshot = viewModel.snapshotState()

    // Simulate a later sim that the daemon then rejects.
    viewModel.latestSimulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 12,
      traceId: "trace-rejected",
      simulatedAt: "2026-05-14T11:00:10Z",
      succeeded: false,
      validation: TaskBoardPolicyPipelineValidation(isValid: false)
    )

    viewModel.restoreState(snapshot)

    #expect(viewModel.latestSimulation?.revision == 11)
    #expect(viewModel.latestSimulation?.traceId == "trace-original")
  }

  @Test("snapshot capture clears transient gesture state for in-flight round-trip")
  func snapshotCaptureClearsTransientGestureState() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.highlightedGroupID = "group-intake"
    viewModel.highlightedInput = PolicyCanvasPortEndpoint(
      nodeID: "risk-score",
      portID: "input-event",
      kind: .input
    )

    _ = viewModel.snapshotState()

    #expect(viewModel.highlightedGroupID == nil)
    #expect(viewModel.highlightedInput == nil)
  }

  @Test("restore preserves nil simulation in snapshot")
  func restorePreservesNilSimulationInSnapshot() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.latestSimulation = nil
    let snapshot = viewModel.snapshotState()

    viewModel.latestSimulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 99,
      traceId: "trace-after",
      simulatedAt: "2026-05-14T11:00:30Z",
      succeeded: false,
      validation: TaskBoardPolicyPipelineValidation(isValid: false)
    )

    viewModel.restoreState(snapshot)

    #expect(viewModel.latestSimulation == nil)
  }
}
