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
}
