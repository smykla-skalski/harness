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
  func makeLivePolicyCanvas(revision: UInt64) async -> Bool
  func goLiveDiffPolicyCanvas(canvasId: String?) async -> TaskBoardPolicyPipelineGoLiveDiff?
  func createPolicyScenario(name: String, input: PolicyInput) async -> Bool
  func updatePolicyScenario(id: String, name: String, input: PolicyInput) async -> Bool
  func deletePolicyScenario(id: String) async -> Bool
  func resetPolicyScenarios() async -> Bool
  func replayPolicyCanvas(canvasId: String?, limit: UInt32?) async
    -> TaskBoardPolicyPipelineReplayResult?
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
    await saveTaskBoardPolicyPipelineDraft(document: document)
  }

  public func makeLivePolicyCanvas(revision: UInt64) async -> Bool {
    await makeLiveTaskBoardPolicyPipeline(revision: revision)
  }

  public func goLiveDiffPolicyCanvas(canvasId: String?) async
    -> TaskBoardPolicyPipelineGoLiveDiff?
  {
    await goLiveDiffTaskBoardPolicyPipeline(canvasId: canvasId)
  }

  public func createPolicyScenario(name: String, input: PolicyInput) async -> Bool {
    await createTaskBoardPolicyScenario(name: name, input: input)
  }

  public func updatePolicyScenario(id: String, name: String, input: PolicyInput) async -> Bool {
    await updateTaskBoardPolicyScenario(id: id, name: name, input: input)
  }

  public func deletePolicyScenario(id: String) async -> Bool {
    await deleteTaskBoardPolicyScenario(id: id)
  }

  public func resetPolicyScenarios() async -> Bool {
    await resetTaskBoardPolicyScenarios()
  }

  public func replayPolicyCanvas(canvasId: String?, limit: UInt32?) async
    -> TaskBoardPolicyPipelineReplayResult?
  {
    await replayTaskBoardPolicyPipeline(canvasId: canvasId, limit: limit)
  }
}
