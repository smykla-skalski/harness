import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

/// One row of the replay panel: how the active draft re-decides a single recorded
/// real decision versus what history actually enforced. Identifiable by the
/// recorded decision id. Carries only value types so the panel never reaches into
/// the wire model.
struct PolicyCanvasReplayRowModel: Identifiable, Equatable {
  let id: String
  let actionTitle: String
  let recordedAt: String
  let historicalVerdict: PolicyCanvasDecisionVerdict
  let draftVerdict: PolicyCanvasDecisionVerdict
  let changed: Bool
  let insufficientEvidence: Bool
  let visitedNodeIds: [String]
}

/// Compact replay header summary: how many recorded decisions were replayed and
/// how many the draft now resolves differently. Nil before the first load so the
/// panel can tell "not replayed yet" from "replayed, nothing recorded".
struct PolicyCanvasReplaySummary: Equatable {
  let sampleSize: Int
  let changedCount: Int
}

extension PolicyCanvasViewModel {
  /// Store a freshly loaded replay alongside the document generation it ran
  /// against, so the panel can later tell whether the draft has moved on without
  /// blanking the comparison the user just asked for.
  func captureReplayResult(_ result: PolicyPipelineReplayResult) {
    latestReplay = result
    replayGeneration = documentGeneration
  }

  /// True when a replay is loaded but the draft has been edited since, so the
  /// history-vs-draft comparison on screen no longer reflects the current draft.
  /// Nil generation (no replay yet, or a preview that injects a result directly)
  /// reads as not stale.
  var replayIsStale: Bool {
    guard latestReplay != nil, let loadedGeneration = replayGeneration else {
      return false
    }
    return loadedGeneration != documentGeneration
  }

  /// Replay rows projected from the latest replay result, in the daemon's
  /// recorded-at-descending order (most recent first). Empty until a replay has
  /// loaded, or when no real decisions have been recorded yet. The verdict
  /// mapping is deterministic, so the panel reads the live feed straight off the
  /// result without touching the wire types.
  var replayRows: [PolicyCanvasReplayRowModel] {
    guard let replay = latestReplay else {
      return []
    }
    return replay.decisions.map { decision in
      PolicyCanvasReplayRowModel(
        id: decision.id,
        actionTitle: decision.action.policyCanvasTitle,
        recordedAt: decision.recordedAt,
        historicalVerdict: PolicyCanvasDecisionVerdict(decision: decision.historicalDecision),
        draftVerdict: PolicyCanvasDecisionVerdict(decision: decision.draftDecision),
        changed: decision.changed,
        insufficientEvidence: decision.insufficientEvidence,
        visitedNodeIds: decision.visitedNodeIds
      )
    }
  }

  /// Replay header summary, or nil before the first replay has loaded.
  var replaySummary: PolicyCanvasReplaySummary? {
    guard let replay = latestReplay else {
      return nil
    }
    return PolicyCanvasReplaySummary(
      sampleSize: Int(replay.sampleSize),
      changedCount: Int(replay.changedCount)
    )
  }
}
