import Foundation
extension HarnessMonitorStore {
  nonisolated static func loadPolicyPipelineSnapshot(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String? = nil
  ) async -> MeasuredOperation<PolicyPipelineDocument?> {
    do {
      let measuredPipeline = try await measureOperation {
        try await client.policyPipeline(canvasId: canvasId)
      }
      return MeasuredOperation(value: measuredPipeline.value, latencyMs: measuredPipeline.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "policy pipeline unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  nonisolated static func loadPolicyCanvasWorkspace(
    using client: any HarnessMonitorClientProtocol
  ) async -> MeasuredOperation<PolicyCanvasWorkspace?> {
    do {
      let measuredWorkspace = try await measureOperation {
        try await client.policyCanvasWorkspace()
      }
      return MeasuredOperation(
        value: measuredWorkspace.value, latencyMs: measuredWorkspace.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "policy workspace unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  public func refreshPolicyPipeline() async {
    guard let client else {
      return
    }
    let measuredWorkspace = await Self.loadPolicyCanvasWorkspace(using: client)
    if let workspace = measuredWorkspace.value {
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      return
    }
    async let pipeline = Self.loadPolicyPipelineSnapshot(using: client)
    async let audit = loadPolicyAudit(using: client)
    let measuredPipeline = await pipeline
    let measuredAudit = await audit

    var fallbackWorkspace = globalPolicyCanvasWorkspace
    if var workspace = fallbackWorkspace, let document = measuredPipeline.value {
      updatePolicyCanvasSummary(
        &workspace,
        canvasId: workspace.activeCanvasId,
        document: document
      )
      if let latestSimulation = measuredAudit?.latestSimulation,
        let activeIndex = workspace.canvases.firstIndex(where: {
          $0.canvasId == workspace.activeCanvasId
        })
      {
        var activeSummary = workspace.canvases[activeIndex]
        activeSummary.latestSimulationTraceId = latestSimulation.traceId
        activeSummary.latestSimulationSucceeded = latestSimulation.succeeded
        activeSummary.latestSimulationAt = latestSimulation.simulatedAt
        workspace.canvases[activeIndex] = activeSummary
      }
      fallbackWorkspace = workspace
    }

    withUISyncBatch {
      globalPolicyCanvasWorkspace = fallbackWorkspace
      globalPolicyPipeline = measuredPipeline.value
      globalPolicySimulation = measuredAudit?.latestSimulation
      globalPolicyAudit = measuredAudit
    }
    await applyEffectivePolicyCanvasSupervisorOverrides(
      for: fallbackWorkspace,
      activeDocument: measuredPipeline.value
    )
  }

  public func ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies() async {
    guard globalPolicyCanvasWorkspace == nil else {
      return
    }
    await bootstrapIfNeeded()
    await refreshPolicyPipeline()
  }

  public func loadTaskBoardPolicyWorkspaceSnapshot() async -> PolicyCanvasWorkspace? {
    if let globalPolicyCanvasWorkspace {
      return globalPolicyCanvasWorkspace
    }
    guard let client else {
      return nil
    }
    return await Self.loadPolicyCanvasWorkspace(using: client).value
  }

  public func adoptTaskBoardPolicyWorkspaceSnapshot(_ workspace: PolicyCanvasWorkspace) {
    guard globalPolicyCanvasWorkspace == nil else {
      return
    }
    globalPolicyCanvasWorkspace = workspace
  }

  /// Persist a draft to the daemon and return the daemon's saved document on
  /// success, `nil` on failure (no client, validation rejected, or transport
  /// error). The daemon bumps the revision on every save, so the returned
  /// document carries a higher revision than the one sent — callers MUST adopt
  /// the returned revision (not the one they sent), otherwise the daemon's own
  /// echo reads as a remote change. Returning `nil` for both invalid and
  /// transport failures preserves the prior Bool contract for the caller's
  /// rollback path; distinguishing the two (tracking-id P3I.3) stays deferred.
  @discardableResult
  public func savePolicyPipelineDraft(
    document: PolicyPipelineDocument
  ) async -> PolicyPipelineDocument? {
    guard let client else {
      return nil
    }
    let existingCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    let loadedWorkspace =
      existingCanvasId == nil
      ? await Self.loadPolicyCanvasWorkspace(using: client).value
      : nil
    if let loadedWorkspace {
      globalPolicyCanvasWorkspace = loadedWorkspace
    }
    guard let canvasId = existingCanvasId ?? loadedWorkspace?.activeCanvasId else {
      return nil
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let response = try await Self.savePolicyPipelineDraft(
        using: client,
        canvasId: canvasId,
        document: document
      )
      return await adoptPolicyPipelineSaveResponse(response)
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }
  nonisolated public static func savePolicyPipelineDraft(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String,
    document: PolicyPipelineDocument
  ) async throws -> PolicyPipelineSaveDraftResponse {
    try await client.savePolicyPipelineDraft(
      request: PolicyPipelineSaveDraftRequest(
        canvasId: canvasId,
        document: document
      )
    )
  }
  @discardableResult
  public func adoptPolicyPipelineSaveResponse(
    _ response: PolicyPipelineSaveDraftResponse
  ) async -> PolicyPipelineDocument? {
    recordRequestSuccess()
    globalPolicyPipeline = response.document
    refreshActivePolicyCanvasSummary(document: response.document)
    await applyEffectivePolicyCanvasSupervisorOverrides(
      for: globalPolicyCanvasWorkspace,
      activeDocument: response.document
    )
    guard response.validation.isValid else {
      presentFailureFeedback(
        response.validation.issues.first?.message ?? "Policy draft is invalid"
      )
      return nil
    }
    let activeCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    if let activeCanvasId, !activeCanvasId.isEmpty {
      _ = await cacheService?.cachePolicyDocument(
        canvasId: activeCanvasId,
        document: response.document
      )
    }
    return response.document
  }
  @discardableResult
  public func simulatePolicyPipeline(
    document: PolicyPipelineDocument? = nil
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let simulation = try await client.simulatePolicyPipeline(
        request: PolicyPipelineSimulateRequest(
          canvasId: globalPolicyCanvasWorkspace?.activeCanvasId,
          document: document
        )
      )
      recordRequestSuccess()
      globalPolicySimulation = simulation
      refreshActivePolicyCanvasSummary(latestSimulation: simulation)
      globalPolicyAudit = await loadPolicyAudit(
        using: client,
        canvasId: globalPolicyCanvasWorkspace?.activeCanvasId
      )
      if simulation.validation.isValid {
        presentSuccessFeedback("Simulated policy")
      } else {
        presentFailureFeedback(
          simulation.validation.issues.first?.message ?? "Policy simulation found issues"
        )
      }
      return simulation.succeeded
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
  @discardableResult
  public func promotePolicyPipeline(revision: UInt64) async -> Bool {
    await makeLivePolicyPipeline(revision: revision)
  }
  nonisolated func loadPolicyAudit(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String? = nil
  ) async -> PolicyPipelineAuditSummary? {
    do {
      return try await client.policyPipelineAudit(canvasId: canvasId)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "policy audit unavailable during refresh: \(description, privacy: .public)"
      )
      return nil
    }
  }
  @discardableResult
  public func createPolicyCanvas(title: String? = nil) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.createPolicyCanvas(
        request: PolicyCanvasCreateRequest(title: title)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Created policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
  @discardableResult
  public func duplicatePolicyCanvas(
    canvasId: String,
    title: String? = nil
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.duplicatePolicyCanvas(
        request: PolicyCanvasDuplicateRequest(canvasId: canvasId, title: title)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Duplicated policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
  @discardableResult
  public func renamePolicyCanvas(
    canvasId: String,
    title: String
  ) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.renamePolicyCanvas(
        request: PolicyCanvasRenameRequest(canvasId: canvasId, title: title)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(workspace, using: client)
      presentSuccessFeedback("Renamed policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
  @discardableResult
  public func activatePolicyCanvas(canvasId: String) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.activatePolicyCanvas(
        request: PolicyCanvasActivateRequest(canvasId: canvasId)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshPolicyPipeline()
      return false
    }
  }
  @discardableResult
  public func deletePolicyCanvas(canvasId: String) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.deletePolicyCanvas(
        request: PolicyCanvasDeleteRequest(canvasId: canvasId)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Deleted policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshPolicyPipeline()
      return false
    }
  }
  @discardableResult
  public func setPolicyCanvasGlobalEnforcement(enabled: Bool) async -> Bool {
    guard let client else {
      return false
    }
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let workspace = try await client.setPolicyCanvasGlobalEnforcement(
        request: PolicyCanvasSetGlobalEnforcementRequest(enabled: enabled)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshPolicyPipeline()
      return false
    }
  }
}
