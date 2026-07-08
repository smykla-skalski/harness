import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

private let mergeDenyFailureEdgeIDs = [
  "edge:evidence-fail:checks-not-green",
  "edge:evidence-fail:branch-protection-blocked",
  "edge:evidence-fail:reviewer-not-approved",
  "edge:evidence-fail:unresolved-requested-changes",
]

/// The four `evidence:merge:fail -> supervisor:merge-deny` edges are one logical
/// transition the daemon splits into four `reason_code` branches. Per
/// algorithm-diagram convention a multigraph collapses to a single drawn edge,
/// so the canvas folds the parallel family into one merged wire on load and
/// expands it back to the four daemon edges on export. These tests pin both
/// halves of that round-trip against the live saved default policy.
@MainActor
struct PolicyCanvasMergedFanInTests {
  private func loadedLiveDefault() -> PolicyCanvasViewModel {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: liveSavedDefaultPolicyDocument(revision: 63),
      simulation: nil,
      audit: nil
    )
    return viewModel
  }

  @Test("live default policy folds the four evidence-failure edges into one wire")
  func mergesFailEdgesIntoOneWire() {
    let intoDeny = loadedLiveDefault().edges.filter { $0.target.nodeID == "supervisor:merge-deny" }
    #expect(intoDeny.count == 1)
    #expect(intoDeny.first?.kind == .error)
  }

  @Test("merged fan-in still exports the four daemon edges with distinct reason codes")
  func exportsFourDaemonFailEdges() {
    let exported = loadedLiveDefault().exportDocument().edges
      .filter { $0.toNodeId == "supervisor:merge-deny" }
    #expect(exported.count == 4)
    #expect(
      Set(exported.compactMap(\.condition.reasonCode)) == [
        PolicyCanvasReasonCode.checksNotGreen,
        PolicyCanvasReasonCode.branchProtectionBlocked,
        PolicyCanvasReasonCode.reviewerNotApproved,
        PolicyCanvasReasonCode.unresolvedRequestedChanges,
      ]
    )
    #expect(Set(exported.map { $0.id.rawValue }) == Set(mergeDenyFailureEdgeIDs))
  }

  @Test("a sim issue on any folded branch tints the one merged wire")
  func severityFoldsOntoMergedWire() async {
    let viewModel = loadedLiveDefault()
    guard
      let merged = viewModel.edges.first(where: { $0.target.nodeID == "supervisor:merge-deny" }),
      let branchDaemonID = merged.branches.first?.daemonEdgeID
    else {
      Issue.record("expected a merged fail wire with at least one branch")
      return
    }
    #expect(merged.isMerged)

    viewModel.latestSimulation = PolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-fold",
      simulatedAt: "2026-05-30T00:00:00Z",
      succeeded: false,
      validation: PolicyPipelineValidation(
        isValid: false,
        issues: [
          PolicyPipelineValidationIssue(
            code: "dangling_edge",
            message: "branch points at missing port",
            edgeId: branchDaemonID
          )
        ]
      )
    )
    viewModel.invalidateValidationCache()
    await applyValidationPresentation(viewModel)

    let edgeSeverities = viewModel.cachedSeverityMaps().edges
    // The issue keys on a folded daemon branch id, which is not a canvas edge.
    // It must light the one wire the user sees (the merged id), not vanish.
    #expect(edgeSeverities[merged.id] == .error)
    #expect(edgeSeverities[branchDaemonID] == nil)
  }

  @Test("editing a branch reason code round-trips through export and undo")
  func editBranchReasonCodeRoundTrips() {
    let viewModel = loadedLiveDefault()
    guard
      let merged = viewModel.edges.first(where: { $0.target.nodeID == "supervisor:merge-deny" }),
      let branch = merged.branches.first(where: {
        $0.reasonCode == PolicyCanvasReasonCode.reviewerNotApproved
      })
    else {
      Issue.record("expected a reviewer_not_approved branch on the merged wire")
      return
    }
    let undo = UndoManager()
    undo.groupsByEvent = false
    viewModel.attachUndoManager(undo)

    undo.beginUndoGrouping()
    viewModel.mutate(
      .setBranchReasonCode(
        edgeID: merged.id,
        daemonEdgeID: branch.daemonEdgeID,
        from: branch.reasonCode,
        to: PolicyCanvasReasonCode.protectedPathTouched
      )
    )
    undo.endUndoGrouping()

    let exported = viewModel.exportDocument().edges.first { $0.id.rawValue == branch.daemonEdgeID }
    #expect(exported?.condition.reasonCode == PolicyCanvasReasonCode.protectedPathTouched)

    undo.undo()
    let reverted = viewModel.edges
      .first { $0.id == merged.id }?
      .branches.first { $0.daemonEdgeID == branch.daemonEdgeID }?
      .reasonCode
    #expect(reverted == PolicyCanvasReasonCode.reviewerNotApproved)
  }

  @Test("retargeting a branch splits it to a new target and exports + undoes")
  func retargetBranchSplitsAndRoundTrips() {
    let viewModel = loadedLiveDefault()
    guard
      let merged = viewModel.edges.first(where: { $0.target.nodeID == "supervisor:merge-deny" }),
      let branch = merged.branches.first(where: {
        $0.reasonCode == PolicyCanvasReasonCode.reviewerNotApproved
      })
    else {
      Issue.record("expected a reviewer_not_approved branch on the merged wire")
      return
    }
    let mergedID = merged.id
    let branchID = branch.daemonEdgeID
    let humanTarget = PolicyCanvasPortEndpoint(
      nodeID: "human:unsafe-action", portID: "in", kind: .input)
    let undo = UndoManager()
    undo.groupsByEvent = false
    viewModel.attachUndoManager(undo)

    undo.beginUndoGrouping()
    viewModel.retargetBranch(edgeID: mergedID, daemonEdgeID: branchID, to: humanTarget)
    undo.endUndoGrouping()

    // The split branch leaves the merge as its own wire to the human gate; the
    // remaining three still merge into deny.
    #expect(viewModel.edges.first { $0.id == branchID }?.target.nodeID == "human:unsafe-action")
    #expect(viewModel.edges.first { $0.id == mergedID }?.branches.count == 3)

    let exported = viewModel.exportDocument().edges
    let split = exported.first { $0.id.rawValue == branchID }
    #expect(split?.toNodeId == "human:unsafe-action")
    #expect(split?.condition.reasonCode == PolicyCanvasReasonCode.reviewerNotApproved)
    #expect(exported.filter { $0.toNodeId == "supervisor:merge-deny" }.count == 3)

    undo.undo()
    let remerged = viewModel.edges.first { $0.target.nodeID == "supervisor:merge-deny" }
    #expect(remerged?.branches.count == 4)
    #expect(viewModel.edges.contains { $0.id == branchID } == false)
  }

  @Test("adding a branch folds a plain edge into a merged wire and undo demotes it")
  func addBranchPromotesPlainEdgeAndUndoes() throws {
    let (viewModel, edgeID, _, targetID) = plainEdgeCanvas()
    let undo = UndoManager()
    undo.groupsByEvent = false
    viewModel.attachUndoManager(undo)
    #expect(viewModel.edges.first { $0.id == edgeID }?.isMerged == false)

    undo.beginUndoGrouping()
    viewModel.addBranch(toEdgeID: edgeID)
    undo.endUndoGrouping()

    let merged = try #require(viewModel.edges.first { $0.target.nodeID == targetID })
    #expect(merged.isMerged)
    #expect(merged.branches.count == 2)
    // The appended branch gets its own daemon id so export emits two edges.
    #expect(Set(merged.branches.map(\.daemonEdgeID)).count == 2)
    #expect(viewModel.exportDocument().edges.filter { $0.toNodeId.rawValue == targetID }.count == 2)

    undo.undo()
    let reverted = try #require(viewModel.edges.first { $0.target.nodeID == targetID })
    #expect(reverted.isMerged == false)
    #expect(reverted.id == edgeID)
  }

  @Test("removing a branch demotes a two-branch wire to a plain edge and undo restores it")
  func removeBranchDemotesAndUndoes() throws {
    let (viewModel, edgeID, _, targetID) = plainEdgeCanvas()
    viewModel.addBranch(toEdgeID: edgeID)
    let merged = try #require(viewModel.edges.first { $0.target.nodeID == targetID })
    let extraBranchID = try #require(merged.branches.last?.daemonEdgeID)
    let undo = UndoManager()
    undo.groupsByEvent = false
    viewModel.attachUndoManager(undo)

    undo.beginUndoGrouping()
    viewModel.removeBranch(edgeID: merged.id, daemonEdgeID: extraBranchID)
    undo.endUndoGrouping()

    let demoted = try #require(viewModel.edges.first { $0.target.nodeID == targetID })
    #expect(demoted.isMerged == false)
    #expect(demoted.branches.count == 1)
    #expect(viewModel.exportDocument().edges.filter { $0.toNodeId.rawValue == targetID }.count == 1)

    undo.undo()
    #expect(viewModel.edges.first { $0.target.nodeID == targetID }?.branches.count == 2)
  }

  @Test("a second drag onto the same source and target appends a branch, not a duplicate edge")
  func secondDragAppendsBranch() throws {
    let (viewModel, _, sourceID, targetID) = plainEdgeCanvas()
    let sourcePort = try #require(viewModel.node(sourceID)?.outputPorts.first?.id)
    let targetPort = try #require(viewModel.node(targetID)?.inputPorts.first?.id)
    #expect(viewModel.edges.count == 1)
    #expect(viewModel.edges.first?.isMerged == false)

    let appended = viewModel.connectDroppedPortPayloads(
      ["policy-canvas-port|\(sourceID)|\(sourcePort)"],
      targetNodeID: targetID,
      targetPortID: targetPort
    )

    #expect(appended)
    #expect(viewModel.edges.count == 1)
    #expect(viewModel.edges.first?.isMerged == true)
    #expect(viewModel.edges.first?.branches.count == 2)
  }

  @Test("changing the selection clears the active-branch highlight")
  func selectionClearsActiveBranch() throws {
    let (viewModel, edgeID, _, _) = plainEdgeCanvas()
    viewModel.addBranch(toEdgeID: edgeID)
    #expect(viewModel.selectedBranchDaemonEdgeID != nil)

    viewModel.select(.node("other-node"))
    #expect(viewModel.selectedBranchDaemonEdgeID == nil)

    viewModel.addBranch(toEdgeID: viewModel.edges.first?.id ?? "")
    #expect(viewModel.selectedBranchDaemonEdgeID != nil)
    viewModel.clearSelection()
    #expect(viewModel.selectedBranchDaemonEdgeID == nil)
  }

  private func plainEdgeCanvas() -> (PolicyCanvasViewModel, String, String, String) {
    let viewModel = PolicyCanvasViewModel(
      nodes: [],
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
    viewModel.createNode(kind: .evidenceCheck, at: CGPoint(x: 100, y: 100))
    let sourceID = viewModel.nodes.last?.id ?? ""
    viewModel.createNode(kind: .humanGate, at: CGPoint(x: 400, y: 100))
    let targetID = viewModel.nodes.last?.id ?? ""
    let sourcePort = viewModel.node(sourceID)?.outputPorts.first?.id ?? ""
    let targetPort = viewModel.node(targetID)?.inputPorts.first?.id ?? ""
    _ = viewModel.connectDroppedPortPayloads(
      ["policy-canvas-port|\(sourceID)|\(sourcePort)"],
      targetNodeID: targetID,
      targetPortID: targetPort
    )
    let edgeID = viewModel.edges.first?.id ?? ""
    return (viewModel, edgeID, sourceID, targetID)
  }

  private func applyValidationPresentation(_ viewModel: PolicyCanvasViewModel) async {
    let worker = PolicyCanvasValidationWorker()
    let output = await worker.compute(
      input: PolicyCanvasValidationWorkerInput(
        nodes: viewModel.nodes,
        edges: viewModel.edges,
        daemonIssues: viewModel.daemonValidationIssues
      )
    )
    viewModel.applyValidationPresentation(output)
  }
}
