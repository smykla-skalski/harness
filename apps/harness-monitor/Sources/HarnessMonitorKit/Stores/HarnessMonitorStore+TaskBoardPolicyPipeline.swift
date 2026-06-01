import Foundation

extension HarnessMonitorStore {
  nonisolated static func loadTaskBoardPolicyPipelineSnapshot(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String? = nil
  ) async -> MeasuredOperation<TaskBoardPolicyPipelineDocument?> {
    do {
      let measuredPipeline = try await measureOperation {
        try await client.taskBoardPolicyPipeline(canvasId: canvasId)
      }
      return MeasuredOperation(value: measuredPipeline.value, latencyMs: measuredPipeline.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board policy pipeline unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  nonisolated static func loadTaskBoardPolicyCanvasWorkspace(
    using client: any HarnessMonitorClientProtocol
  ) async -> MeasuredOperation<TaskBoardPolicyCanvasWorkspace?> {
    do {
      let measuredWorkspace = try await measureOperation {
        try await client.taskBoardPolicyCanvasWorkspace()
      }
      return MeasuredOperation(
        value: measuredWorkspace.value, latencyMs: measuredWorkspace.latencyMs)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board policy workspace unavailable during refresh: \(description, privacy: .public)"
      )
      return MeasuredOperation(value: nil, latencyMs: 0)
    }
  }

  public func refreshTaskBoardPolicyPipeline() async {
    guard let client else {
      return
    }
    let measuredWorkspace = await Self.loadTaskBoardPolicyCanvasWorkspace(using: client)
    if let workspace = measuredWorkspace.value {
      await syncTaskBoardPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      return
    }

    async let pipeline = Self.loadTaskBoardPolicyPipelineSnapshot(using: client)
    async let audit = loadTaskBoardPolicyAudit(using: client)
    let measuredPipeline = await pipeline
    let measuredAudit = await audit

    withUISyncBatch {
      globalTaskBoardPolicyCanvasWorkspace = nil
      globalTaskBoardPolicyPipeline = measuredPipeline.value
      globalTaskBoardPolicySimulation = measuredAudit?.latestSimulation
      globalTaskBoardPolicyAudit = measuredAudit
    }
    await applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
      for: nil,
      activeDocument: measuredPipeline.value
    )
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
  public func saveTaskBoardPolicyPipelineDraft(
    document: TaskBoardPolicyPipelineDocument
  ) async -> TaskBoardPolicyPipelineDocument? {
    guard let client else {
      return nil
    }
    let existingCanvasId = globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId
    let loadedWorkspace =
      existingCanvasId == nil
      ? await Self.loadTaskBoardPolicyCanvasWorkspace(using: client).value
      : nil
    if let loadedWorkspace {
      globalTaskBoardPolicyCanvasWorkspace = loadedWorkspace
    }
    guard let canvasId = existingCanvasId ?? loadedWorkspace?.activeCanvasId else {
      return nil
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await Self.saveTaskBoardPolicyPipelineDraft(
        using: client,
        canvasId: canvasId,
        document: document
      )
      return await adoptTaskBoardPolicyPipelineSaveResponse(response)
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  nonisolated public static func saveTaskBoardPolicyPipelineDraft(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String,
    document: TaskBoardPolicyPipelineDocument
  ) async throws -> TaskBoardPolicyPipelineSaveDraftResponse {
    try await client.saveTaskBoardPolicyPipelineDraft(
      request: TaskBoardPolicyPipelineSaveDraftRequest(
        canvasId: canvasId,
        document: document
      )
    )
  }

  @discardableResult
  public func adoptTaskBoardPolicyPipelineSaveResponse(
    _ response: TaskBoardPolicyPipelineSaveDraftResponse
  ) async -> TaskBoardPolicyPipelineDocument? {
    recordRequestSuccess()
    globalTaskBoardPolicyPipeline = response.document
    refreshActivePolicyCanvasSummary(document: response.document)
    await applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
      for: globalTaskBoardPolicyCanvasWorkspace,
      activeDocument: response.document
    )
    guard response.validation.isValid else {
      presentFailureFeedback(
        response.validation.issues.first?.message ?? "Policy draft is invalid"
      )
      return nil
    }
    return response.document
  }

  @discardableResult
  public func simulateTaskBoardPolicyPipeline(
    document: TaskBoardPolicyPipelineDocument? = nil
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let simulation = try await client.simulateTaskBoardPolicyPipeline(
        request: TaskBoardPolicyPipelineSimulateRequest(
          canvasId: globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId,
          document: document
        )
      )
      recordRequestSuccess()
      globalTaskBoardPolicySimulation = simulation
      refreshActivePolicyCanvasSummary(latestSimulation: simulation)
      globalTaskBoardPolicyAudit = await loadTaskBoardPolicyAudit(
        using: client,
        canvasId: globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId
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
  public func promoteTaskBoardPolicyPipeline(revision: UInt64) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await client.promoteTaskBoardPolicyPipeline(
        request: TaskBoardPolicyPipelinePromoteRequest(
          canvasId: globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId,
          revision: revision
        )
      )
      recordRequestSuccess()
      globalTaskBoardPolicyPipeline = response.document
      refreshActivePolicyCanvasSummary(document: response.document)
      globalTaskBoardPolicyAudit = await loadTaskBoardPolicyAudit(
        using: client,
        canvasId: globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId
      )
      await applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
        for: globalTaskBoardPolicyCanvasWorkspace,
        activeDocument: response.document
      )
      presentSuccessFeedback("Promoted policy")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  nonisolated func loadTaskBoardPolicyAudit(
    using client: any HarnessMonitorClientProtocol,
    canvasId: String? = nil
  ) async -> TaskBoardPolicyPipelineAuditSummary? {
    do {
      return try await client.taskBoardPolicyPipelineAudit(canvasId: canvasId)
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board policy audit unavailable during refresh: \(description, privacy: .public)"
      )
      return nil
    }
  }

  @discardableResult
  public func createTaskBoardPolicyCanvas(title: String? = nil) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.createTaskBoardPolicyCanvas(
        request: TaskBoardPolicyCanvasCreateRequest(title: title)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
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
  public func duplicateTaskBoardPolicyCanvas(
    canvasId: String,
    title: String? = nil
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.duplicateTaskBoardPolicyCanvas(
        request: TaskBoardPolicyCanvasDuplicateRequest(canvasId: canvasId, title: title)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
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
  public func renameTaskBoardPolicyCanvas(
    canvasId: String,
    title: String
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.renameTaskBoardPolicyCanvas(
        request: TaskBoardPolicyCanvasRenameRequest(canvasId: canvasId, title: title)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(workspace, using: client)
      presentSuccessFeedback("Renamed policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  @discardableResult
  public func activateTaskBoardPolicyCanvas(canvasId: String) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.activateTaskBoardPolicyCanvas(
        request: TaskBoardPolicyCanvasActivateRequest(canvasId: canvasId)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardPolicyPipeline()
      return false
    }
  }

  @discardableResult
  public func deleteTaskBoardPolicyCanvas(canvasId: String) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.deleteTaskBoardPolicyCanvas(
        request: TaskBoardPolicyCanvasDeleteRequest(canvasId: canvasId)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Deleted policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardPolicyPipeline()
      return false
    }
  }

  @discardableResult
  public func toggleTaskBoardPolicyCanvasEnforcement() async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let workspace = try await client.toggleTaskBoardPolicyCanvasEnforcement(
        request: TaskBoardPolicyCanvasToggleEnforcementRequest()
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback(
        workspace.policyEnforcementKillSwitchActive
          ? "Disabled policy enforcement"
          : "Restored policy enforcement"
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      await refreshTaskBoardPolicyPipeline()
      return false
    }
  }

}
