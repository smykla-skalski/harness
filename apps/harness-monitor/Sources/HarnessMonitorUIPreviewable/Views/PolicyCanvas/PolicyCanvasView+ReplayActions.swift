import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasView {
  /// Replay the active draft over the recorded real-decision feed and store the
  /// result for the confidence panel's replay section. Read-only: it never
  /// mutates the draft or the pipeline, so there is no reload afterwards. The
  /// next edit clears the result (see `markDocumentDirty`), so a shown replay
  /// always matches the draft on screen. Remote-action gated like the other
  /// canvas daemon calls.
  func loadReplay() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    Task { @MainActor in
      viewModel.isReplaying = true
      defer { viewModel.isReplaying = false }
      guard let result = await runtime?.replayPolicyCanvas(canvasId: nil, limit: nil) else {
        statusLine = "Could not load replay"
        return
      }
      viewModel.latestReplay = result
    }
  }
}
