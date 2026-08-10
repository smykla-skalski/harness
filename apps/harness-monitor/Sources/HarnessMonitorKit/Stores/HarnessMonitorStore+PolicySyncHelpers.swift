import Foundation

private struct PolicyCanvasActiveArtifacts {
  let shouldReload: Bool
  let document: PolicyPipelineDocument?
  let audit: PolicyPipelineAuditSummary?
}

extension HarnessMonitorStore {
  @discardableResult
  func applyEffectivePolicyCanvasSupervisorOverrides(
    for workspace: PolicyCanvasWorkspace?,
    activeDocument: PolicyPipelineDocument? = nil,
    taskBoardSourceGeneration: UInt64
  ) async -> Bool {
    guard let registry = supervisorStack?.registry else {
      return true
    }
    let overrides = await effectivePolicyCanvasSupervisorOverrides(
      for: workspace,
      activeDocument: activeDocument
    )
    return await registry.applyOverrides(
      overrides,
      sourceGeneration: taskBoardSourceGeneration
    )
  }

  private func effectivePolicyCanvasSupervisorOverrides(
    for workspace: PolicyCanvasWorkspace?,
    activeDocument: PolicyPipelineDocument?
  ) async -> [PolicyConfigOverride] {
    guard let workspace else {
      guard let activeDocument, activeDocument.mode == .enforced else {
        return await loadPolicyOverrides()
      }
      return activeDocument.supervisorPolicyOverrides()
    }
    let liveDocuments = workspace.canvases.compactMap { canvas in
      canvas.liveDocument ?? (canvas.mode == .enforced ? canvas.document : nil)
    }
    guard !liveDocuments.isEmpty else {
      return await loadPolicyOverrides()
    }
    return liveDocuments.flatMap { $0.supervisorPolicyOverrides() }
  }

  private func loadPolicyCanvasActiveArtifacts(
    for workspace: PolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    forceReload: Bool,
    access: TaskBoardClientAccess
  ) async -> PolicyCanvasActiveArtifacts? {
    let shouldReload =
      forceReload
      || globalPolicyCanvasWorkspace?.activeCanvasId != workspace.activeCanvasId
      || globalPolicyPipeline == nil
    guard shouldReload else {
      return PolicyCanvasActiveArtifacts(
        shouldReload: false,
        document: globalPolicyPipeline,
        audit: globalPolicyAudit
      )
    }
    async let pipeline = Self.loadPolicyPipelineSnapshot(
      using: client,
      canvasId: workspace.activeCanvasId
    )
    async let audit = loadPolicyAudit(
      using: client,
      canvasId: workspace.activeCanvasId
    )
    let pipelineLoad = await pipeline
    let measuredAudit = await audit
    guard taskBoardAccessIsCurrent(access), let measuredPipeline = pipelineLoad.measured else {
      return nil
    }
    return PolicyCanvasActiveArtifacts(
      shouldReload: true,
      document: measuredPipeline.value,
      audit: measuredAudit
    )
  }

  @discardableResult
  func syncPolicyCanvasWorkspace(
    _ workspace: PolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    forceReloadActiveCanvas: Bool = false,
    taskBoardAccess: TaskBoardClientAccess
  ) async -> Bool {
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    guard
      let artifacts = await loadPolicyCanvasActiveArtifacts(
        for: workspace,
        using: client,
        forceReload: forceReloadActiveCanvas,
        access: taskBoardAccess
      )
    else { return false }
    var syncedWorkspace = workspace
    let activeDocument = artifacts.document

    guard
      let hydratedWorkspace = await hydrateEffectivePolicyCanvasWorkspace(
        syncedWorkspace,
        using: client,
        activeDocument: activeDocument
      )
    else { return false }
    syncedWorkspace = hydratedWorkspace
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    guard
      await applyEffectivePolicyCanvasSupervisorOverrides(
        for: syncedWorkspace,
        activeDocument: activeDocument,
        taskBoardSourceGeneration: taskBoardAccess.databaseAccessGeneration
      )
    else { return false }
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    if artifacts.shouldReload, let activeDocument {
      guard
        await cachePolicyDocument(
          activeDocument,
          canvasId: syncedWorkspace.activeCanvasId,
          access: taskBoardAccess
        )
      else { return false }
    }
    withUISyncBatch {
      globalPolicyCanvasWorkspace = syncedWorkspace
      if artifacts.shouldReload {
        globalPolicyPipeline = activeDocument
        globalPolicySimulation = artifacts.audit?.latestSimulation
        globalPolicyAudit = artifacts.audit
      }
    }
    return taskBoardAccessIsCurrent(taskBoardAccess)
  }

  func cachePolicyDocument(
    _ document: PolicyPipelineDocument,
    canvasId: String,
    access: TaskBoardClientAccess
  ) async -> Bool {
    guard taskBoardAccessIsCurrent(access) else { return false }
    guard let cacheService else { return true }
    let write = await cacheService.cachePolicyDocument(
      canvasId: canvasId,
      document: document
    )
    guard taskBoardAccessIsCurrent(access) else {
      if let token = write.token {
        await cacheService.rollbackPolicyDocumentCacheWrite(token)
      }
      return false
    }
    return true
  }

  func hydrateEffectivePolicyCanvasWorkspace(
    _ workspace: PolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    activeDocument: PolicyPipelineDocument?
  ) async -> PolicyCanvasWorkspace? {
    var hydratedWorkspace = workspace
    if let activeDocument {
      updatePolicyCanvasSummary(
        &hydratedWorkspace,
        canvasId: workspace.activeCanvasId,
        document: activeDocument
      )
    }
    let missingEnforcedCanvasIDs: [String] = hydratedWorkspace.canvases.compactMap { canvas in
      guard canvas.mode == .enforced, canvas.document == nil, canvas.liveDocument == nil else {
        return nil
      }
      return canvas.canvasId
    }
    guard !missingEnforcedCanvasIDs.isEmpty else {
      return hydratedWorkspace
    }

    var allDocumentsLoaded = true
    await withTaskGroup(
      of: (String, TaskBoardSnapshotLoad<PolicyPipelineDocument>).self
    ) { group in
      for canvasId in missingEnforcedCanvasIDs {
        group.addTask {
          let pipelineLoad = await Self.loadPolicyPipelineSnapshot(
            using: client,
            canvasId: canvasId
          )
          return (canvasId, pipelineLoad)
        }
      }
      for await (canvasId, pipelineLoad) in group {
        guard let measuredPipeline = pipelineLoad.measured else {
          allDocumentsLoaded = false
          continue
        }
        self.updatePolicyCanvasSummary(
          &hydratedWorkspace,
          canvasId: canvasId,
          document: measuredPipeline.value
        )
      }
    }
    return allDocumentsLoaded ? hydratedWorkspace : nil
  }

  func updatePolicyCanvasSummary(
    _ workspace: inout PolicyCanvasWorkspace,
    canvasId: String,
    document: PolicyPipelineDocument
  ) {
    guard let index = workspace.canvases.firstIndex(where: { $0.canvasId == canvasId }) else {
      return
    }
    workspace.canvases[index].document = document
    if document.mode == .enforced {
      workspace.canvases[index].liveDocument = document
      workspace.canvases[index].liveUpdatedAt =
        workspace.canvases[index].liveUpdatedAt ?? workspace.canvases[index].updatedAt
    }
    workspace.canvases[index].revision = document.revision
    workspace.canvases[index].mode = document.mode
    workspace.canvases[index].nodeCount = document.nodes.count
    workspace.canvases[index].edgeCount = document.edges.count
    workspace.canvases[index].groupCount = document.groups.count
  }

  func refreshActivePolicyCanvasSummary(
    document: PolicyPipelineDocument? = nil,
    latestSimulation: PolicyPipelineSimulationResult? = nil
  ) {
    guard var workspace = globalPolicyCanvasWorkspace,
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
    globalPolicyCanvasWorkspace = workspace
  }

  public func exportPolicyCanvas(
    canvasId: String? = nil
  ) async -> PolicyCanvasExportResponse? {
    guard let access = availableTaskBoardClientAccess else { return nil }
    do {
      let response = try await access.client.exportPolicyCanvas(
        request: PolicyCanvasExportRequest(canvasId: canvasId)
      )
      try requireCurrentTaskBoardClientAccess(access)
      return response
    } catch {
      return nil
    }
  }

  @discardableResult
  public func importPolicyCanvas(
    document: PolicyPipelineDocument,
    title: String? = nil
  ) async -> Bool {
    await withSerializedTaskBoardPolicyPublication {
      await importPolicyCanvasSerialized(document: document, title: title)
    }
  }

  private func importPolicyCanvasSerialized(
    document: PolicyPipelineDocument,
    title: String?
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    let client = access.client
    beginDaemonAction()
    defer { endDaemonAction() }
    do {
      let workspace = try await client.importPolicyCanvas(
        request: PolicyCanvasImportRequest(document: document, title: title)
      )
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      guard
        await syncPolicyCanvasWorkspace(
          workspace,
          using: client,
          forceReloadActiveCanvas: true,
          taskBoardAccess: access
        )
      else { return false }
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback("Imported policy canvas")
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
