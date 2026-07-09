import Foundation

extension HarnessMonitorStore {
  /// Read-only replay of the active draft against the recorded real-decision
  /// feed: re-simulates the draft over the last `limit` enforced decisions and
  /// returns where it would now decide differently than history. Returns `nil`
  /// when there is no client or the request fails. The replay panel passes the
  /// active canvas id so the sample matches the canvas on screen.
  public func replayPolicyPipeline(
    canvasId: String? = nil,
    limit: UInt32? = nil
  ) async -> PolicyPipelineReplayResult? {
    guard let client else {
      return nil
    }
    do {
      return try await client.replayPolicyPipeline(
        request: PolicyPipelineReplayRequest(
          canvasId: canvasId ?? globalPolicyCanvasWorkspace?.activeCanvasId,
          limit: limit
        )
      )
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
