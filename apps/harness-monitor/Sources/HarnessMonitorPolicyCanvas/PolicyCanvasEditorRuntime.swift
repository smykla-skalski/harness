import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms

@MainActor
public protocol PolicyCanvasLabRuntime: AnyObject {
  var policyCanvasSnapshot: PolicyCanvasHostSnapshot { get }

  func bootstrapPolicyCanvas() async
  func refreshPolicyCanvas() async
}

@MainActor
public protocol PolicyCanvasEditorRuntime: PolicyCanvasLabRuntime {
  var policyCanvasActionInFlight: Bool { get set }

  func simulatePolicyCanvas(document: TaskBoardPolicyPipelineDocument) async -> Bool
  func savePolicyCanvasDraft(document: TaskBoardPolicyPipelineDocument) async
    -> TaskBoardPolicyPipelineDocument?
  func promotePolicyCanvas(revision: UInt64) async -> Bool
}

extension HarnessMonitorStore: PolicyCanvasEditorRuntime {
  public var policyCanvasSnapshot: PolicyCanvasHostSnapshot {
    let dashboard = contentUI.dashboard
    return PolicyCanvasHostSnapshot(
      activeCanvasId: dashboard.taskBoardPolicyCanvasWorkspace?.activeCanvasId,
      document: dashboard.taskBoardPolicyPipeline,
      simulation: dashboard.taskBoardPolicySimulation,
      audit: dashboard.taskBoardPolicyAudit,
      workspace: dashboard.taskBoardPolicyCanvasWorkspace
    )
  }

  public var policyCanvasActionInFlight: Bool {
    get { isDaemonActionInFlight }
    set { isDaemonActionInFlight = newValue }
  }

  public func bootstrapPolicyCanvas() async {
    await bootstrapIfNeeded()
  }

  public func refreshPolicyCanvas() async {
    await refreshTaskBoardPolicyPipeline()
  }

  public func simulatePolicyCanvas(document: TaskBoardPolicyPipelineDocument) async -> Bool {
    await simulateTaskBoardPolicyPipeline(document: document)
  }

  public func savePolicyCanvasDraft(document: TaskBoardPolicyPipelineDocument) async
    -> TaskBoardPolicyPipelineDocument?
  {
    guard let client = apiClient,
      let canvasId = globalTaskBoardPolicyCanvasWorkspace?.activeCanvasId
    else {
      return nil
    }
    do {
      let response = try await HarnessMonitorStore.saveTaskBoardPolicyPipelineDraft(
        using: client,
        canvasId: canvasId,
        document: document
      )
      return await adoptTaskBoardPolicyPipelineSaveResponse(response)
    } catch {
      return nil
    }
  }

  public func promotePolicyCanvas(revision: UInt64) async -> Bool {
    await promoteTaskBoardPolicyPipeline(revision: revision)
  }
}
