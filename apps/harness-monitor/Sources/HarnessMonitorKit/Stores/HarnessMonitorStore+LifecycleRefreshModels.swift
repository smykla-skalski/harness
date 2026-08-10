struct RefreshApplyOptions {
  let preserveSelection: Bool
  let allowPreviewReadySelection: Bool
  let recordConnectionTelemetry: Bool
  let isInitialConnect: Bool
  let adoptsLocalManifest: Bool
}

struct TaskBoardConfirmationTick {
  var resolvedItems: [TaskBoardItem]
  var resolvedStatus: TaskBoardOrchestratorStatus?
  var automationSnapshot: TaskBoardAutomationSnapshot?
  var positionMutationGeneration: UInt64
  var shouldApply: Bool
  var shouldKeepWaiting: Bool
}
