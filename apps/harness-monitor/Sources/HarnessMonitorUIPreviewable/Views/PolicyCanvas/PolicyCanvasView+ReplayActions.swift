import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasView {
  /// Replay the active draft over the recorded real-decision feed and store the
  /// result for the confidence panel's replay section. Read-only: it never
  /// mutates the draft or the pipeline, so there is no reload afterwards. A later
  /// edit keeps the result but marks it stale (see `captureReplayResult` and
  /// `replayIsStale`), so the comparison stays on screen with a refresh prompt
  /// instead of vanishing. Remote-action gated like the other canvas daemon
  /// calls.
  func loadReplay() {
    guard remoteActionsEnabled else {
      statusLine = remoteActionDisabledReason
      return
    }
    viewModel.isReplaying = true
    HarnessMonitorAsyncWorkQueue.shared.submit(
      HarnessMonitorAsyncWorkQueue.WorkItem(title: "Replaying policy decisions") {
        let result = await replayPolicyCanvasRuntime()
        await MainActor.run {
          defer { viewModel.isReplaying = false }
          guard let result else {
            statusLine = "Could not load replay"
            return
          }
          viewModel.captureReplayResult(result)
        }
      }
    )
  }

  @MainActor
  private func replayPolicyCanvasRuntime() async -> TaskBoardPolicyPipelineReplayResult? {
    await runtime?.replayPolicyCanvas(canvasId: nil, limit: nil)
  }
}
