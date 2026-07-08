import Foundation

extension HarnessMonitorStore {
  /// Make the saved revision the live, enforced policy in one step: the daemon
  /// promotes the canvas (mode -> Enforced) and turns global enforcement on, then
  /// returns the post-promotion workspace snapshot so the client can land the new
  /// summaries, active document, audit, and global flag through a single
  /// `syncPolicyCanvasWorkspace`. Returns `true` on success, `false` for
  /// no client or any daemon/transport failure (the toast surfaces the reason).
  @discardableResult
  public func makeLivePolicyPipeline(revision: UInt64) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await client.makeLivePolicyPipeline(
        request: PolicyPipelineMakeLiveRequest(
          canvasId: globalPolicyCanvasWorkspace?.activeCanvasId,
          revision: revision
        )
      )
      recordRequestSuccess()
      globalPolicyPipeline = response.document
      // The response workspace already reflects the Enforced canvas mode and the
      // enabled global flag; force-reload the active canvas so the audit + the
      // supervisor overrides re-derive from the now-live document in one pass.
      await syncPolicyCanvasWorkspace(
        response.workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Policy is live")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  /// Read-only preview of how making the draft live would change decisions versus
  /// the currently enforced policy. Returns the per-scenario live-vs-draft diff,
  /// or `nil` when there is no client or the request fails. The go-live sheet
  /// passes only the canvas id so the preview matches the saved revision
  /// `makeLivePolicyPipeline` will enforce.
  public func goLiveDiffPolicyPipeline(
    canvasId: String? = nil
  ) async -> PolicyPipelineGoLiveDiff? {
    guard let client else {
      return nil
    }
    do {
      return try await client.goLiveDiffPolicyPipeline(
        request: PolicyPipelineGoLiveDiffRequest(
          canvasId: canvasId ?? globalPolicyCanvasWorkspace?.activeCanvasId
        )
      )
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
