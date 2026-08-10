import Foundation

public struct TaskBoardPolicyWorkspaceSnapshot: Sendable {
  public let workspace: PolicyCanvasWorkspace
  let access: TaskBoardClientAccess
}

extension HarnessMonitorStore {
  nonisolated static func loadPolicyPipelineSnapshot(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String? = nil
  ) async -> TaskBoardSnapshotLoad<PolicyPipelineDocument> {
    do {
      let measuredPipeline = try await measureOperation {
        try await client.policyPipeline(canvasId: canvasId)
      }
      return TaskBoardSnapshotLoad(measured: measuredPipeline)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "policy pipeline unavailable during refresh: \(description, privacy: .public)"
      )
      return TaskBoardSnapshotLoad(measured: nil)
    }
  }

  nonisolated static func loadPolicyCanvasWorkspace(
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardSnapshotLoad<PolicyCanvasWorkspace> {
    do {
      let measuredWorkspace = try await measureOperation {
        try await client.policyCanvasWorkspace()
      }
      return TaskBoardSnapshotLoad(measured: measuredWorkspace)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "policy workspace unavailable during refresh: \(description, privacy: .public)"
      )
      return TaskBoardSnapshotLoad(measured: nil)
    }
  }

  @discardableResult
  public func refreshPolicyPipeline() async -> Bool {
    await withSerializedTaskBoardPolicyPublication(cancellationResult: false) {
      await refreshPolicyPipelineSerialized()
    }
  }

  private func refreshPolicyPipelineSerialized() async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    let workspaceLoad = await Self.loadPolicyCanvasWorkspace(using: client)
    guard taskBoardAccessIsCurrent(access) else { return false }
    guard let measuredWorkspace = workspaceLoad.measured else {
      return handleTaskBoardPolicyRecoveryFailure(access: access)
    }
    let synchronized = await syncPolicyCanvasWorkspace(
      measuredWorkspace.value,
      using: client,
      forceReloadActiveCanvas: true,
      taskBoardAccess: access
    )
    guard synchronized, taskBoardAccessIsCurrent(access) else {
      return handleTaskBoardPolicyRecoveryFailure(access: access)
    }
    await completeTaskBoardPolicyRecovery()
    return true
  }

  public func ensurePolicyCanvasWorkspaceLoadedForRuntimePolicies() async {
    guard globalPolicyCanvasWorkspace == nil || taskBoardPolicyRuntimeRecoveryPending else {
      return
    }
    await bootstrapIfNeeded()
    await refreshPolicyPipeline()
  }

  public func loadTaskBoardPolicyWorkspaceSnapshot() async -> TaskBoardPolicyWorkspaceSnapshot? {
    guard globalPolicyCanvasWorkspace == nil else { return nil }
    guard let access = availableTaskBoardClientAccess else { return nil }
    let workspace = await Self.loadPolicyCanvasWorkspace(using: access.client).measured?.value
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
    await withSerializedTaskBoardPolicyPublication(cancellationResult: nil) {
      await savePolicyPipelineDraftSerialized(document: document)
    }
  }

  private func savePolicyPipelineDraftSerialized(
    document: PolicyPipelineDocument
  ) async -> PolicyPipelineDocument? {
    guard let access = availableTaskBoardClientAccess else { return nil }
    let client = access.client
    let existingCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    let loadedWorkspace =
      existingCanvasId == nil
      ? await Self.loadPolicyCanvasWorkspace(using: client).measured?.value
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
    await withSerializedTaskBoardPolicyPublication(cancellationResult: false) {
      await simulatePolicyPipelineSerialized(document: document)
    }
  }

  private func simulatePolicyPipelineSerialized(
    document: PolicyPipelineDocument?
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
