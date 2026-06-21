import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels

/// Phase 6 replay inspector: the per-decision row projection over the latest
/// replay result, plus the header summary. The mapping is deterministic (wire
/// shape -> row shape), so hand-built fixtures cover the projection; the real
/// recorded-feed round-trip is proven by the daemon reader test.
@Suite("Policy canvas replay inspector")
@MainActor
struct PolicyCanvasReplayInspectorTests {
  @Test("Replay rows project one row per recorded decision")
  func rowsProjectPerDecision() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestReplay = result(
      sampleSize: 3,
      changedCount: 1,
      decisions: [
        decision(
          id: "d1", action: .mergePr,
          historical: .allow(reasonCode: .autoMergeAllowed, policyVersion: "v1"),
          draft: .deny(reasonCode: .checksNotGreen, policyVersion: "v1"),
          changed: true, insufficient: false, visited: ["n1", "n2"]
        ),
        decision(
          id: "d2", action: .spawnAgent,
          historical: .requireHuman(reasonCode: .humanRequired, policyVersion: "v1"),
          draft: .requireHuman(reasonCode: .humanRequired, policyVersion: "v1"),
          changed: false, insufficient: false, visited: ["n3"]
        ),
        decision(
          id: "d3", action: .accessSecret,
          historical: .allow(reasonCode: .autoMergeAllowed, policyVersion: "v1"),
          draft: .deny(reasonCode: .missingMergeEvidence, policyVersion: "v1"),
          changed: false, insufficient: true, visited: []
        ),
      ]
    )

    let rows = viewModel.replayRows
    #expect(rows.count == 3)

    #expect(rows[0].id == "d1")
    #expect(rows[0].actionTitle == "Merge PR")
    #expect(rows[0].historicalVerdict == .allow)
    #expect(rows[0].draftVerdict == .deny)
    #expect(rows[0].changed)
    #expect(!rows[0].insufficientEvidence)
    #expect(rows[0].visitedNodeIds == ["n1", "n2"])

    #expect(rows[1].historicalVerdict == .needsHuman)
    #expect(rows[1].draftVerdict == .needsHuman)
    #expect(!rows[1].changed)

    #expect(rows[2].insufficientEvidence)
    #expect(rows[2].draftVerdict == .deny)

    #expect(viewModel.replaySummary == PolicyCanvasReplaySummary(sampleSize: 3, changedCount: 1))
  }

  @Test("No replay yields no rows and no summary")
  func noReplayHasNoRowsOrSummary() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    #expect(viewModel.latestReplay == nil)
    #expect(viewModel.replayRows.isEmpty)
    #expect(viewModel.replaySummary == nil)
  }

  @Test("A loaded empty feed has a summary but no rows")
  func loadedEmptyFeedHasSummaryButNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestReplay = result(sampleSize: 0, changedCount: 0, decisions: [])
    #expect(viewModel.replayRows.isEmpty)
    #expect(viewModel.replaySummary == PolicyCanvasReplaySummary(sampleSize: 0, changedCount: 0))
  }

  private func decision(
    id: String,
    action: PolicyAction,
    historical: PolicyDecision,
    draft: PolicyDecision,
    changed: Bool,
    insufficient: Bool,
    visited: [String]
  ) -> PolicyPipelineReplayDecision {
    PolicyPipelineReplayDecision(
      id: id,
      recordedAt: "2026-06-20T10:00:00Z",
      action: action,
      historicalDecision: historical,
      draftDecision: draft,
      visitedNodeIds: visited,
      changed: changed,
      insufficientEvidence: insufficient
    )
  }

  private func result(
    sampleSize: UInt,
    changedCount: UInt,
    decisions: [PolicyPipelineReplayDecision]
  ) -> TaskBoardPolicyPipelineReplayResult {
    TaskBoardPolicyPipelineReplayResult(
      sampleSize: sampleSize,
      changedCount: changedCount,
      decisions: decisions
    )
  }
}
