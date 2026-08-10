import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func createPolicyCanvas(title: String? = nil) async -> Bool {
    await mutatePolicyCanvas(successMessage: "Created policy canvas") { client in
      try await client.createPolicyCanvas(request: PolicyCanvasCreateRequest(title: title))
    }
  }

  @discardableResult
  public func duplicatePolicyCanvas(
    canvasId: String,
    title: String? = nil
  ) async -> Bool {
    await mutatePolicyCanvas(successMessage: "Duplicated policy canvas") { client in
      try await client.duplicatePolicyCanvas(
        request: PolicyCanvasDuplicateRequest(canvasId: canvasId, title: title)
      )
    }
  }

  @discardableResult
  public func renamePolicyCanvas(canvasId: String, title: String) async -> Bool {
    await mutatePolicyCanvas(
      successMessage: "Renamed policy canvas",
      forceReloadActiveCanvas: false
    ) { client in
      try await client.renamePolicyCanvas(
        request: PolicyCanvasRenameRequest(canvasId: canvasId, title: title)
      )
    }
  }

  @discardableResult
  public func activatePolicyCanvas(canvasId: String) async -> Bool {
    await mutatePolicyCanvas(refreshOnFailure: true) { client in
      try await client.activatePolicyCanvas(
        request: PolicyCanvasActivateRequest(canvasId: canvasId)
      )
    }
  }

  @discardableResult
  public func deletePolicyCanvas(canvasId: String) async -> Bool {
    await mutatePolicyCanvas(
      successMessage: "Deleted policy canvas",
      refreshOnFailure: true
    ) { client in
      try await client.deletePolicyCanvas(
        request: PolicyCanvasDeleteRequest(canvasId: canvasId)
      )
    }
  }

  @discardableResult
  public func setPolicyCanvasGlobalEnforcement(enabled: Bool) async -> Bool {
    await mutatePolicyCanvas(refreshOnFailure: true) { client in
      try await client.setPolicyCanvasGlobalEnforcement(
        request: PolicyCanvasSetGlobalEnforcementRequest(enabled: enabled)
      )
    }
  }

  private func mutatePolicyCanvas(
    successMessage: String? = nil,
    forceReloadActiveCanvas: Bool = true,
    refreshOnFailure: Bool = false,
    mutation: (any HarnessMonitorClientProtocol) async throws -> PolicyCanvasWorkspace
  ) async -> Bool {
    await withSerializedTaskBoardPolicyPublication {
      await mutatePolicyCanvasSerialized(
        successMessage: successMessage,
        forceReloadActiveCanvas: forceReloadActiveCanvas,
        refreshOnFailure: refreshOnFailure,
        mutation: mutation
      )
    }
  }

  private func mutatePolicyCanvasSerialized(
    successMessage: String?,
    forceReloadActiveCanvas: Bool,
    refreshOnFailure: Bool,
    mutation: (any HarnessMonitorClientProtocol) async throws -> PolicyCanvasWorkspace
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await mutation(client)
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      guard
        await syncPolicyCanvasWorkspace(
          workspace,
          using: client,
          forceReloadActiveCanvas: forceReloadActiveCanvas,
          taskBoardAccess: access
        )
      else { return false }
      try requireCurrentTaskBoardClientAccess(access)
      if let successMessage {
        presentSuccessFeedback(successMessage)
      }
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
      presentFailureFeedback(error.localizedDescription)
      if refreshOnFailure {
        Task { @MainActor [weak self] in
          await self?.refreshPolicyPipeline()
        }
      }
      return false
    }
  }
}
