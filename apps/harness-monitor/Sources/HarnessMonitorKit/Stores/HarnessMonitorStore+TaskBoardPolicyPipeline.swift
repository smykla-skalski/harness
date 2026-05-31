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
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let response = try await client.saveTaskBoardPolicyPipelineDraft(
        request: TaskBoardPolicyPipelineSaveDraftRequest(
          canvasId: globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId,
          document: document
        )
      )
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
      presentSuccessFeedback("Saved policy draft")
      return response.document
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
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

  nonisolated private func loadTaskBoardPolicyAudit(
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
      return false
    }
  }

  private func applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
    for workspace: TaskBoardPolicyCanvasWorkspace?,
    activeDocument: TaskBoardPolicyPipelineDocument? = nil
  ) async {
    guard let registry = supervisorStack?.registry else {
      return
    }
    guard let workspace else {
      if let activeDocument, activeDocument.mode == .enforced {
        await registry.applyOverrides(activeDocument.supervisorPolicyOverrides())
        return
      }
      await registry.applyOverrides(await loadPolicyOverrides())
      return
    }
    let enforcedCanvases = workspace.canvases.filter { $0.mode == .enforced }
    guard !enforcedCanvases.isEmpty else {
      await registry.applyOverrides(await loadPolicyOverrides())
      return
    }
    await registry.applyOverrides(
      enforcedCanvases.compactMap(\.document).flatMap { $0.supervisorPolicyOverrides() }
    )
  }

  private func syncTaskBoardPolicyCanvasWorkspace(
    _ workspace: TaskBoardPolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    forceReloadActiveCanvas: Bool = false
  ) async {
    let previousActiveCanvasId = globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId
    let shouldReloadActiveCanvas =
      forceReloadActiveCanvas
      || previousActiveCanvasId != workspace.activeCanvasId
      || globalTaskBoardPolicyPipeline == nil
    var syncedWorkspace = workspace
    var activeDocument = globalTaskBoardPolicyPipeline
    var activeAudit = globalTaskBoardPolicyAudit

    if shouldReloadActiveCanvas {
      async let pipeline = Self.loadTaskBoardPolicyPipelineSnapshot(
        using: client,
        canvasId: workspace.activeCanvasId
      )
      async let audit = loadTaskBoardPolicyAudit(
        using: client,
        canvasId: workspace.activeCanvasId
      )
      let measuredPipeline = await pipeline
      let measuredAudit = await audit
      activeDocument = measuredPipeline.value
      activeAudit = measuredAudit
    }

    syncedWorkspace = await hydrateEffectiveTaskBoardPolicyCanvasWorkspace(
      syncedWorkspace,
      using: client,
      activeDocument: activeDocument
    )
    withUISyncBatch {
      globalTaskBoardPolicyCanvasWorkspace = syncedWorkspace
      if shouldReloadActiveCanvas {
        globalTaskBoardPolicyPipeline = activeDocument
        globalTaskBoardPolicySimulation = activeAudit?.latestSimulation
        globalTaskBoardPolicyAudit = activeAudit
      }
    }
    await applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
      for: syncedWorkspace,
      activeDocument: activeDocument
    )
  }

  private func hydrateEffectiveTaskBoardPolicyCanvasWorkspace(
    _ workspace: TaskBoardPolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    activeDocument: TaskBoardPolicyPipelineDocument?
  ) async -> TaskBoardPolicyCanvasWorkspace {
    var hydratedWorkspace = workspace
    if let activeDocument {
      updatePolicyCanvasSummary(
        &hydratedWorkspace,
        canvasId: workspace.activeCanvasId,
        document: activeDocument
      )
    }
    let missingEnforcedCanvasIDs: [String] = hydratedWorkspace.canvases.compactMap { canvas in
      guard canvas.mode == .enforced, canvas.document == nil else {
        return nil
      }
      return canvas.canvasId
    }
    guard !missingEnforcedCanvasIDs.isEmpty else {
      return hydratedWorkspace
    }

    await withTaskGroup(of: (String, TaskBoardPolicyPipelineDocument?).self) { group in
      for canvasId in missingEnforcedCanvasIDs {
        group.addTask {
          let measuredPipeline = await Self.loadTaskBoardPolicyPipelineSnapshot(
            using: client,
            canvasId: canvasId
          )
          return (canvasId, measuredPipeline.value)
        }
      }
      for await (canvasId, document) in group {
        guard let document else {
          continue
        }
        self.updatePolicyCanvasSummary(
          &hydratedWorkspace,
          canvasId: canvasId,
          document: document
        )
      }
    }
    return hydratedWorkspace
  }

  private func updatePolicyCanvasSummary(
    _ workspace: inout TaskBoardPolicyCanvasWorkspace,
    canvasId: String,
    document: TaskBoardPolicyPipelineDocument
  ) {
    guard let index = workspace.canvases.firstIndex(where: { $0.canvasId == canvasId }) else {
      return
    }
    workspace.canvases[index].document = document
    workspace.canvases[index].revision = document.revision
    workspace.canvases[index].mode = document.mode
    workspace.canvases[index].nodeCount = document.nodes.count
    workspace.canvases[index].edgeCount = document.edges.count
    workspace.canvases[index].groupCount = document.groups.count
  }

  private func refreshActivePolicyCanvasSummary(
    document: TaskBoardPolicyPipelineDocument? = nil,
    latestSimulation: TaskBoardPolicyPipelineSimulationResult? = nil
  ) {
    guard var workspace = globalTaskBoardPolicyCanvasWorkspace,
      let activeIndex = workspace.canvases.firstIndex(where: {
        $0.canvasId == workspace.activeCanvasId
      })
    else {
      return
    }

    if let document {
      updatePolicyCanvasSummary(
        &workspace,
        canvasId: workspace.activeCanvasId,
        document: document
      )
    }
    var summary = workspace.canvases[activeIndex]
    if let latestSimulation {
      summary.latestSimulationTraceId = latestSimulation.traceId
      summary.latestSimulationSucceeded = latestSimulation.succeeded
      summary.latestSimulationAt = latestSimulation.simulatedAt
    }
    workspace.canvases[activeIndex] = summary
    globalTaskBoardPolicyCanvasWorkspace = workspace
  }
}
