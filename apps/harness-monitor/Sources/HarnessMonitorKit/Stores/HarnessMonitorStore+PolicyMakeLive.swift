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
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let response = try await client.makeLivePolicyPipeline(
        request: PolicyPipelineMakeLiveRequest(
          canvasId: globalPolicyCanvasWorkspace?.activeCanvasId,
          revision: revision
        )
      )
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      globalPolicyPipeline = response.document
      // The response workspace already reflects the Enforced canvas mode and the
      // enabled global flag; force-reload the active canvas so the audit + the
      // supervisor overrides re-derive from the now-live document in one pass.
      guard
        await syncPolicyCanvasWorkspace(
          response.workspace,
          using: client,
          forceReloadActiveCanvas: true,
          taskBoardAccess: access
        )
      else { return false }
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback("Policy is live")
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
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
    guard let access = availableTaskBoardClientAccess else { return nil }
    do {
      let result = try await access.client.goLiveDiffPolicyPipeline(
        request: PolicyPipelineGoLiveDiffRequest(
          canvasId: canvasId ?? globalPolicyCanvasWorkspace?.activeCanvasId
        )
      )
      try requireCurrentTaskBoardClientAccess(access)
      return result
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
}
