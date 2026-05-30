import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

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
    #expect(Set(exported.map(\.id)) == Set(mergeDenyFailureEdgeIDs))
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

    viewModel.latestSimulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-fold",
      simulatedAt: "2026-05-30T00:00:00Z",
      succeeded: false,
      validation: TaskBoardPolicyPipelineValidation(
        isValid: false,
        issues: [
          TaskBoardPolicyPipelineValidationIssue(
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
