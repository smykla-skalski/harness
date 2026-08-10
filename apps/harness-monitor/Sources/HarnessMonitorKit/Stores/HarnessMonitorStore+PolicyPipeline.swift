import Foundation

public struct TaskBoardPolicyWorkspaceSnapshot: Sendable {
  public let workspace: PolicyCanvasWorkspace
  let access: TaskBoardClientAccess
}

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
    guard let access = availableTaskBoardClientAccess else { return }
    let client = access.client
    let measuredWorkspace = await Self.loadPolicyCanvasWorkspace(using: client)
    guard taskBoardAccessIsCurrent(access) else { return }
    if let workspace = measuredWorkspace.value {
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true,
        taskBoardAccess: access
      )
      return
    }
    async let pipeline = Self.loadPolicyPipelineSnapshot(using: client)
    async let audit = loadPolicyAudit(using: client)
    let measuredPipeline = await pipeline
    let measuredAudit = await audit
    guard taskBoardAccessIsCurrent(access) else { return }

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

    guard
      await applyEffectivePolicyCanvasSupervisorOverrides(
        for: fallbackWorkspace,
        activeDocument: measuredPipeline.value,
        taskBoardSourceGeneration: access.databaseAccessGeneration
      ),
      taskBoardAccessIsCurrent(access)
    else { return }
    if let document = measuredPipeline.value,
      let canvasId = fallbackWorkspace?.activeCanvasId
    {
      guard
        await cachePolicyDocument(
          document,
          canvasId: canvasId,
          access: access
        )
      else { return }
    }
    withUISyncBatch {
      globalPolicyCanvasWorkspace = fallbackWorkspace
      globalPolicyPipeline = measuredPipeline.value
      globalPolicySimulation = measuredAudit?.latestSimulation
      globalPolicyAudit = measuredAudit
    }
  }

  public func ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies() async {
    guard globalPolicyCanvasWorkspace == nil else {
      return
    }
    await bootstrapIfNeeded()
    await refreshPolicyPipeline()
  }

  public func loadTaskBoardPolicyWorkspaceSnapshot() async -> TaskBoardPolicyWorkspaceSnapshot? {
    guard globalPolicyCanvasWorkspace == nil else { return nil }
    guard let access = availableTaskBoardClientAccess else { return nil }
    let workspace = await Self.loadPolicyCanvasWorkspace(using: access.client).value
    guard taskBoardAccessIsCurrent(access), let workspace else { return nil }
    return TaskBoardPolicyWorkspaceSnapshot(workspace: workspace, access: access)
  }

  public func adoptTaskBoardPolicyWorkspaceSnapshot(_ snapshot: TaskBoardPolicyWorkspaceSnapshot) {
    guard
      globalPolicyCanvasWorkspace == nil,
      taskBoardAccessIsCurrent(snapshot.access)
    else {
      return
    }
    globalPolicyCanvasWorkspace = snapshot.workspace
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
    guard let access = availableTaskBoardClientAccess else { return nil }
    let client = access.client
    let existingCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    let loadedWorkspace =
      existingCanvasId == nil
      ? await Self.loadPolicyCanvasWorkspace(using: client).value
      : nil
    guard taskBoardAccessIsCurrent(access) else { return nil }
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
      try requireCurrentTaskBoardClientAccess(access)
      return await adoptPolicyPipelineSaveResponse(response, access: access)
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
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
  func adoptPolicyPipelineSaveResponse(
    _ response: PolicyPipelineSaveDraftResponse,
    access: TaskBoardClientAccess
  ) async -> PolicyPipelineDocument? {
    guard taskBoardAccessIsCurrent(access) else { return nil }
    guard
      await applyEffectivePolicyCanvasSupervisorOverrides(
        for: globalPolicyCanvasWorkspace,
        activeDocument: response.document,
        taskBoardSourceGeneration: access.databaseAccessGeneration
      ),
      taskBoardAccessIsCurrent(access)
    else { return nil }
    guard response.validation.isValid else {
      presentFailureFeedback(
        response.validation.issues.first?.message ?? "Policy draft is invalid"
      )
      return nil
    }
    let activeCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    if let activeCanvasId, !activeCanvasId.isEmpty {
      guard
        await cachePolicyDocument(
          response.document,
          canvasId: activeCanvasId,
          access: access
        )
      else { return nil }
    }
    recordRequestSuccess()
    globalPolicyPipeline = response.document
    refreshActivePolicyCanvasSummary(document: response.document)
    return response.document
  }
  @discardableResult
  public func simulatePolicyPipeline(
    document: PolicyPipelineDocument? = nil
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let simulation = try await client.simulatePolicyPipeline(
        request: PolicyPipelineSimulateRequest(
          canvasId: globalPolicyCanvasWorkspace?.activeCanvasId,
          document: document
        )
      )
      try requireCurrentTaskBoardClientAccess(access)
      let audit = await loadPolicyAudit(
        using: client,
        canvasId: globalPolicyCanvasWorkspace?.activeCanvasId
      )
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      globalPolicySimulation = simulation
      globalPolicyAudit = audit
      refreshActivePolicyCanvasSummary(latestSimulation: simulation)
      if simulation.validation.isValid {
        presentSuccessFeedback("Simulated policy")
      } else {
        presentFailureFeedback(
          simulation.validation.issues.first?.message ?? "Policy simulation found issues"
        )
      }
      return simulation.succeeded
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
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
}
