import Foundation

extension HarnessMonitorStore {
  func applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
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
    let liveDocuments = workspace.canvases.compactMap { canvas in
      canvas.liveDocument ?? (canvas.mode == .enforced ? canvas.document : nil)
    }
    guard !liveDocuments.isEmpty else {
      await registry.applyOverrides(await loadPolicyOverrides())
      return
    }
    await registry.applyOverrides(
      liveDocuments.flatMap { $0.supervisorPolicyOverrides() }
    )
  }

  func syncTaskBoardPolicyCanvasWorkspace(
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
    let activeCanvasId = syncedWorkspace.activeCanvasId
    if shouldReloadActiveCanvas, let doc = activeDocument, !activeCanvasId.isEmpty {
      _ = await cacheService?.cacheTaskBoardPolicyDocument(canvasId: activeCanvasId, document: doc)
    }
    await applyEffectiveTaskBoardPolicyCanvasSupervisorOverrides(
      for: syncedWorkspace,
      activeDocument: activeDocument
    )
  }

  func hydrateEffectiveTaskBoardPolicyCanvasWorkspace(
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
      guard canvas.mode == .enforced, canvas.document == nil, canvas.liveDocument == nil else {
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

  func updatePolicyCanvasSummary(
    _ workspace: inout TaskBoardPolicyCanvasWorkspace,
    canvasId: String,
    document: TaskBoardPolicyPipelineDocument
  ) {
    guard let index = workspace.canvases.firstIndex(where: { $0.canvasId == canvasId }) else {
      return
    }
    workspace.canvases[index].document = document
    if document.mode == .enforced {
      workspace.canvases[index].liveDocument = document
      workspace.canvases[index].liveUpdatedAt = workspace.canvases[index].updatedAt
    }
    workspace.canvases[index].revision = document.revision
    workspace.canvases[index].mode = document.mode
    workspace.canvases[index].nodeCount = document.nodes.count
    workspace.canvases[index].edgeCount = document.edges.count
    workspace.canvases[index].groupCount = document.groups.count
  }

  func refreshActivePolicyCanvasSummary(
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

  public func exportTaskBoardPolicyCanvas(
    canvasId: String? = nil
  ) async -> TaskBoardPolicyExportResponse? {
    guard let client else { return nil }
    return try? await client.exportTaskBoardPolicy(
      request: TaskBoardPolicyExportRequest(canvasId: canvasId)
    )
  }

  @discardableResult
  public func importTaskBoardPolicyCanvas(
    document: TaskBoardPolicyPipelineDocument,
    title: String? = nil
  ) async -> Bool {
    guard let client else { return false }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }
    do {
      let workspace = try await client.importTaskBoardPolicy(
        request: TaskBoardPolicyImportRequest(document: document, title: title)
      )
      recordRequestSuccess()
      await syncTaskBoardPolicyCanvasWorkspace(
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
