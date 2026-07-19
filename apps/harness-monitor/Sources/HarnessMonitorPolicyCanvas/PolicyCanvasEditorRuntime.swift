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

  func simulatePolicyCanvas(document: PolicyPipelineDocument) async -> Bool
  func savePolicyCanvasDraft(document: PolicyPipelineDocument) async
    -> PolicyPipelineDocument?
  func makeLivePolicyCanvas(revision: UInt64) async -> Bool
  func goLiveDiffPolicyCanvas(canvasId: String?) async -> PolicyPipelineGoLiveDiff?
  func createPolicyScenario(name: String, input: PolicyInput) async -> Bool
  func updatePolicyScenario(id: String, name: String, input: PolicyInput) async -> Bool
  func deletePolicyScenario(id: String) async -> Bool
  func resetPolicyScenarios() async -> Bool
  func replayPolicyCanvas(canvasId: String?, limit: UInt32?) async
    -> PolicyPipelineReplayResult?
}

extension HarnessMonitorStore: PolicyCanvasEditorRuntime {
  public var policyCanvasSnapshot: PolicyCanvasHostSnapshot {
    let dashboard = contentUI.dashboard
    return PolicyCanvasHostSnapshot(
      activeCanvasId: dashboard.policyCanvasWorkspace?.activeCanvasId,
      document: dashboard.policyPipeline,
      simulation: dashboard.policySimulation,
      audit: dashboard.policyAudit,
      workspace: dashboard.policyCanvasWorkspace
    )
  }

  public var policyCanvasActionInFlight: Bool {
    get { isDaemonActionInFlight }
    set {
      if newValue {
        beginDaemonAction()
      } else {
        endDaemonAction()
      }
    }
  }

  public func bootstrapPolicyCanvas() async {
    await bootstrapIfNeeded()
  }

  public func refreshPolicyCanvas() async {
    await refreshPolicyPipeline()
  }

  public func simulatePolicyCanvas(document: PolicyPipelineDocument) async -> Bool {
    await simulatePolicyPipeline(document: document)
  }

  public func savePolicyCanvasDraft(document: PolicyPipelineDocument) async
    -> PolicyPipelineDocument?
  {
    await savePolicyPipelineDraft(document: document)
  }

  public func makeLivePolicyCanvas(revision: UInt64) async -> Bool {
    await makeLivePolicyPipeline(revision: revision)
  }

  public func goLiveDiffPolicyCanvas(canvasId: String?) async
    -> PolicyPipelineGoLiveDiff?
  {
    await goLiveDiffPolicyPipeline(canvasId: canvasId)
  }

  public func replayPolicyCanvas(canvasId: String?, limit: UInt32?) async
    -> PolicyPipelineReplayResult?
  {
    await replayPolicyPipeline(canvasId: canvasId, limit: limit)
  }
}
