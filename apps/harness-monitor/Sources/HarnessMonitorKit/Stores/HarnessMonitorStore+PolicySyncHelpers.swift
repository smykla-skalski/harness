import Foundation

extension HarnessMonitorStore {
  @discardableResult
  func applyEffectivePolicyCanvasSupervisorOverrides(
    for workspace: PolicyCanvasWorkspace?,
    activeDocument: PolicyPipelineDocument? = nil,
    taskBoardSourceGeneration: UInt64? = nil
  ) async -> Bool {
    guard let registry = supervisorStack?.registry else {
      return true
    }
    let overrides = await effectivePolicyCanvasSupervisorOverrides(
      for: workspace,
      activeDocument: activeDocument
    )
    if let taskBoardSourceGeneration {
      return await registry.applyOverrides(
        overrides,
        sourceGeneration: taskBoardSourceGeneration
      )
    }
    await registry.applyOverrides(overrides)
    return true
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

  @discardableResult
  func syncPolicyCanvasWorkspace(
    _ workspace: PolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    forceReloadActiveCanvas: Bool = false,
    taskBoardAccess: TaskBoardClientAccess? = nil
  ) async -> Bool {
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    let previousActiveCanvasId = globalPolicyCanvasWorkspace?.activeCanvasId
    let shouldReloadActiveCanvas =
      forceReloadActiveCanvas
      || previousActiveCanvasId != workspace.activeCanvasId
      || globalPolicyPipeline == nil
    var syncedWorkspace = workspace
    var activeDocument = globalPolicyPipeline
    var activeAudit = globalPolicyAudit

    if shouldReloadActiveCanvas {
      async let pipeline = Self.loadPolicyPipelineSnapshot(
        using: client,
        canvasId: workspace.activeCanvasId
      )
      async let audit = loadPolicyAudit(
        using: client,
        canvasId: workspace.activeCanvasId
      )
      let measuredPipeline = await pipeline
      let measuredAudit = await audit
      guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
      activeDocument = measuredPipeline.value
      activeAudit = measuredAudit
    }

    syncedWorkspace = await hydrateEffectivePolicyCanvasWorkspace(
      syncedWorkspace,
      using: client,
      activeDocument: activeDocument
    )
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    guard
      await applyEffectivePolicyCanvasSupervisorOverrides(
        for: syncedWorkspace,
        activeDocument: activeDocument,
        taskBoardSourceGeneration: taskBoardAccess?.databaseAccessGeneration
      )
    else { return false }
    guard taskBoardAccessIsCurrent(taskBoardAccess) else { return false }
    withUISyncBatch {
      globalPolicyCanvasWorkspace = syncedWorkspace
      if shouldReloadActiveCanvas {
        globalPolicyPipeline = activeDocument
        globalPolicySimulation = activeAudit?.latestSimulation
        globalPolicyAudit = activeAudit
      }
    }
    let activeCanvasId = syncedWorkspace.activeCanvasId
    if taskBoardAccess == nil,
      shouldReloadActiveCanvas,
      let doc = activeDocument,
      !activeCanvasId.isEmpty
    {
      _ = await cacheService?.cachePolicyDocument(canvasId: activeCanvasId, document: doc)
    }
    return taskBoardAccessIsCurrent(taskBoardAccess)
  }

  private func taskBoardAccessIsCurrent(_ access: TaskBoardClientAccess?) -> Bool {
    guard let access else { return true }
    return (try? requireCurrentTaskBoardClientAccess(access)) != nil
  }

  func hydrateEffectivePolicyCanvasWorkspace(
    _ workspace: PolicyCanvasWorkspace,
    using client: any HarnessMonitorClientProtocol,
    activeDocument: PolicyPipelineDocument?
  ) async -> PolicyCanvasWorkspace {
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

    await withTaskGroup(of: (String, PolicyPipelineDocument?).self) { group in
      for canvasId in missingEnforcedCanvasIDs {
        group.addTask {
          let measuredPipeline = await Self.loadPolicyPipelineSnapshot(
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
    guard let client else { return nil }
    return try? await client.exportPolicyCanvas(
      request: PolicyCanvasExportRequest(canvasId: canvasId)
    )
  }

  @discardableResult
  public func importPolicyCanvas(
    document: PolicyPipelineDocument,
    title: String? = nil
  ) async -> Bool {
    guard let client else { return false }
    beginDaemonAction()
    defer { endDaemonAction() }
    do {
      let workspace = try await client.importPolicyCanvas(
        request: PolicyCanvasImportRequest(document: document, title: title)
      )
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(
        workspace,
        using: client,
        forceReloadActiveCanvas: true
      )
      presentSuccessFeedback("Imported policy canvas")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
