import Foundation

@testable import HarnessMonitorKit

struct ProjectFixture {
  let name: String
  let projectDir: String?
  let contextRoot: String
  var activeSessionCount: Int
  var totalSessionCount: Int
}

struct RecordedReviewBodyUpdateRequest: Equatable {
  let pullRequestID: String
  let expectedPriorBodySHA256: String
  let newBody: String
}

struct RecordingTaskBoardSyncStub {
  var importedItems: [TaskBoardItem]?
  var summary = TaskBoardSyncSummary(total: 0, providers: [])
  var error: (any Error)?
}

final class RecordingHarnessClient: HarnessMonitorClientProtocol, @unchecked Sendable {
  enum Call: Equatable {
    case assignTask(sessionID: String, taskID: String, agentID: String, actor: String)
    case changeRole(sessionID: String, agentID: String, role: SessionRole, actor: String)
    case checkpointTask(
      sessionID: String,
      taskID: String,
      summary: String,
      progress: Int,
      actor: String
    )
    case submitTaskForReview(
      sessionID: String,
      taskID: String,
      actor: String,
      summary: String?,
      suggestedPersona: String?
    )
    case claimTaskReview(sessionID: String, taskID: String, actor: String)
    case submitTaskReview(
      sessionID: String,
      taskID: String,
      actor: String,
      verdict: ReviewVerdict,
      summary: String,
      points: [ReviewPoint]
    )
    case respondTaskReview(
      sessionID: String,
      taskID: String,
      actor: String,
      agreed: [String],
      disputed: [String],
      note: String?
    )
    case arbitrateTask(
      sessionID: String,
      taskID: String,
      actor: String,
      verdict: ReviewVerdict,
      summary: String
    )
    case applyImproverPatch(
      sessionID: String,
      actor: String,
      issueID: String,
      target: ImproverTarget,
      relPath: String,
      newContents: String,
      projectDir: String,
      dryRun: Bool
    )
    case reconfigureHostBridge(enable: [String], disable: [String], force: Bool)
    case createTask(
      sessionID: String,
      title: String,
      context: String?,
      severity: TaskSeverity,
      actor: String
    )
    case deleteTask(sessionID: String, taskID: String, actor: String)
    case dropTask(
      sessionID: String,
      taskID: String,
      target: TaskDropTarget,
      queuePolicy: TaskQueuePolicy,
      actor: String
    )
    case interruptCodexRun(runID: String)
    case startAgentTui(
      sessionID: String,
      runtime: String,
      name: String?,
      prompt: String?,
      projectDir: String?,
      persona: String?,
      argv: [String],
      rows: Int,
      cols: Int
    )
    case startAcpAgent(
      sessionID: String,
      agentID: String,
      role: SessionRole,
      fallbackRole: SessionRole?,
      capabilities: [String],
      name: String?,
      prompt: String?,
      projectDir: String?,
      persona: String?,
      model: String?,
      effort: String?,
      allowCustomModel: Bool,
      recordPermissions: Bool
    )
    case sendAgentTuiInput(tuiID: String, request: AgentTuiInputRequest)
    case resizeAgentTui(tuiID: String, rows: Int, cols: Int)
    case stopAgentTui(tuiID: String)
    case adoptSession(bookmarkID: String?, sessionRoot: URL)
    case startSession(projectDir: String, baseRef: String?)
    case endSession(sessionID: String, actor: String)
    case removeSession(sessionID: String, actor: String)
    case observeSession(sessionID: String, actor: String)
    case removeAgent(sessionID: String, agentID: String, actor: String)
    case resolveCodexApproval(
      runID: String,
      approvalID: String,
      decision: CodexApprovalDecision
    )
    case resolveAcpPermission(
      agentID: String,
      batchID: String,
      decision: AcpPermissionDecision
    )
    case sendSignal(sessionID: String, agentID: String, command: String, actor: String)
    case cancelSignal(sessionID: String, agentID: String, signalID: String, actor: String)
    case startCodexRun(
      sessionID: String,
      prompt: String,
      mode: CodexRunMode,
      actor: String?,
      resumeThreadID: String?
    )
    case steerCodexRun(runID: String, prompt: String)
    case startVoiceSession(
      sessionID: String,
      localeIdentifier: String,
      sinks: [VoiceProcessingSink],
      routeTarget: VoiceRouteTarget,
      requiresConfirmation: Bool,
      remoteProcessorURL: String?,
      actor: String
    )
    case appendVoiceAudioChunk(voiceSessionID: String, sequence: UInt64, actor: String)
    case appendVoiceTranscript(voiceSessionID: String, sequence: UInt64, actor: String)
    case finishVoiceSession(
      voiceSessionID: String,
      reason: VoiceSessionFinishReason,
      confirmedText: String?,
      actor: String
    )
    case transferLeader(sessionID: String, newLeaderID: String, reason: String?, actor: String)
    case startTaskBoardOrchestrator
    case stopTaskBoardOrchestrator
    case runTaskBoardOrchestratorOnce(
      itemID: String?,
      dryRun: Bool?,
      status: TaskBoardStatus?,
      projectDir: String?
    )
    case dispatchTaskBoard(
      dryRun: Bool,
      status: TaskBoardStatus?,
      itemID: String?,
      projectDir: String?,
      actor: String?
    )
    case evaluateTaskBoard(
      dryRun: Bool,
      status: TaskBoardStatus?,
      itemID: String?
    )
    case createTaskBoardItem(title: String, priority: TaskBoardPriority)
    case updateTaskBoardItem(
      id: String,
      status: TaskBoardStatus?
    )
    case deleteTaskBoardItem(id: String)
    case beginTaskBoardPlan(id: String)
    case submitTaskBoardPlan(id: String, summary: String)
    case approveTaskBoardPlan(id: String, approvedBy: String, approvedAt: String?)
    case revokeTaskBoardPlan(id: String, actor: String?)
    case updateTaskBoardOrchestratorSettings(
      policyVersion: String?,
      clearProjectDir: Bool,
      clearDispatchStatusFilter: Bool
    )
    case updateTaskBoardGitRuntimeConfig(overrideCount: Int)
    case syncTaskBoardGitRuntimeKeyMaterial(overrideCount: Int)
    case syncTaskBoardGitHubTokens(
      globalTokenConfigured: Bool,
      repositoryTokenCount: Int
    )
    case syncTaskBoardTodoistToken(tokenConfigured: Bool)
    case syncTaskBoardOpenRouterToken(tokenConfigured: Bool)
    case taskBoardGitIdentityDefaults
    case verifyTaskBoardGitSigning(repository: String?)
    case prepareTaskBoardSecretHandoff
    case ackTaskBoardSecretHandoff(migrationID: String, digest: String)
    case syncTaskBoard(
      direction: TaskBoardExternalSyncDirection,
      dryRun: Bool,
      status: TaskBoardStatus?,
      provider: TaskBoardExternalProvider?
    )
    case auditTaskBoard(status: TaskBoardStatus?)
    case taskBoardProjects(status: TaskBoardStatus?)
    case taskBoardMachines(status: TaskBoardStatus?)
    case taskBoardHostLocal
    case taskBoardHostList
    case setTaskBoardHostProjectTypes(projectTypes: [String])
    case savePolicyPipelineDraft(revision: UInt64)
    case simulatePolicyPipeline
    case promotePolicyPipeline(revision: UInt64)
    case makeLivePolicyPipeline(revision: UInt64)
    case updateTaskQueuePolicy(
      sessionID: String,
      taskID: String,
      queuePolicy: TaskQueuePolicy,
      actor: String
    )
    case updateTask(
      sessionID: String,
      taskID: String,
      status: TaskStatus,
      note: String?,
      actor: String
    )
  }

  enum ReadCall {
    case health
    case transportLatency
    case diagnostics
    case projects
    case sessions
    case taskBoardItems(TaskBoardStatus?)
    case sessionDetail(String)
    case timeline(String)
    case timelineWindow(String)
    case acpTranscript(String)
    case codexTranscript(String)
    case taskBoardOrchestratorStatus
    case taskBoardOrchestratorSettings
    case taskBoardGitRuntimeConfig
    case policyCanvasWorkspace
    case policyPipeline
    case policyPipelineAudit
  }

  let lock = NSLock()
  var callsStorage: [Call] = []
  var detailStorage: SessionDetail
  var healthDelay: Duration?
  var transportLatencyMsValue: Int?
  var transportLatencyError: (any Error)?
  var diagnosticsDelay: Duration?
  var diagnosticsReportOverride: DaemonDiagnosticsReport?
  var projectsDelay: Duration?
  var sessionsDelay: Duration?
  var queuedDiagnosticsErrors: [any Error] = []
  var queuedProjectsErrors: [any Error] = []
  var queuedSessionsErrors: [any Error] = []
  var queuedTaskBoardItemsErrors: [any Error] = []
  var mutationDelay: Duration?
  var archiveSessionMutatesReadSnapshots = true
  var archiveSessionError: (any Error)?
  var projectSummariesStorage: [ProjectSummary]?
  var sessionSummariesStorage: [SessionSummary]?
  var taskBoardItemsStorage: [TaskBoardItem] = []
  var taskBoardCapabilitiesValue = TaskBoardCapabilities(
    storage: "database",
    revision: 0,
    instanceID: "recording-task-board"
  )
  var queuedTaskBoardItemSnapshots: [[TaskBoardItem]] = []
  var taskBoardSyncStub = RecordingTaskBoardSyncStub()
  var taskBoardAuditSummaryStorage: TaskBoardAuditSummary?
  var taskBoardProjectSummariesStorage: [TaskBoardProjectSummary]?
  var taskBoardMachineSummariesStorage: [TaskBoardMachineSummary]?
  var taskBoardUpdateError: (any Error)?
  var taskBoardRuntimeConfigError: (any Error)?
  var taskBoardOrchestratorSettingsError: (any Error)?
  var taskBoardGitHubTokensSyncError: (any Error)?
  var taskBoardTodoistTokenSyncError: (any Error)?
  var taskBoardGitIdentityDefaultsValue = TaskBoardGitIdentityDefaults()
  var taskBoardGitSigningVerifyValue: TaskBoardGitSigningVerifyResponse = .skipped
  var taskBoardSecretHandoffStub = RecordingTaskBoardSecretHandoffStub()
  var policyValidationOverride: PolicyPipelineValidation?
  var policySimulationOverride: Bool?
  var policyCanvasWorkspaceError: (any Error)?
  var policyCanvasWorkspaceStorage: PolicyCanvasWorkspace?
  var policyPipelinesByCanvasID: [String: PolicyPipelineDocument] = [:]
  var policyAuditByCanvasID: [String: PolicyPipelineAuditSummary] = [:]
  var policyCanvasIDCounter = 1
  var savedPolicyCanvasIDs: [String?] = []
  var simulatedPolicyCanvasIDs: [String?] = []
  var promotedPolicyCanvasIDs: [String?] = []
  var sessionDetailsByID: [String: SessionDetail] = [:]
  var detailDelaysBySessionID: [String: Duration] = [:]
  var sessionDetailErrorsByID: [String: any Error] = [:]
  var sessionDetailScopesByID: [String: [String?]] = [:]
  var recordedTraceContextsByOperation: [String: [[String: String]]] = [:]
  var timelinesBySessionID: [String: [TimelineEntry]] = [:]
  var timelineScopesBySessionID: [String: [TimelineScope]] = [:]
  var timelineWindowRequestsBySessionID: [String: [TimelineWindowRequest]] = [:]
  var timelineWindowResponsesBySessionID: [String: TimelineWindowResponse] = [:]
  var timelineBatchesBySessionID: [String: [[TimelineEntry]]] = [:]
  var timelineDelaysBySessionID: [String: Duration] = [:]
  var timelineWindowDelaysBySessionID: [String: Duration] = [:]
  var timelineBatchDelaysBySessionID: [String: Duration] = [:]
  var timelineErrorsBySessionID: [String: any Error] = [:]
  var timelineWindowErrorsBySessionID: [String: any Error] = [:]
  var reviewBodyResponses: [String: ReviewsBodyResponse] = [:]
  var reviewBodyFetchedIDs: [String] = []
  var reviewBodyFetchHook: (@Sendable (String) async -> Void)?
  var reviewBodyUpdateOutcomes: [String: ReviewsBodyUpdateResponse] = [:]
  var reviewBodyUpdateRequests: [RecordedReviewBodyUpdateRequest] = []
  var reviewBodyUpdateErrors: [String: any Error] = [:]
  var reviewCommentResponse: ReviewsActionResponse?
  var reviewCommentRequests: [ReviewsCommentRequest] = []
  var reviewCommentError: (any Error)?
  var reviewPolicyPreviewResponse: ReviewsPolicyPreviewResponse?
  var reviewPolicyPreviewRequests: [ReviewsPolicyPreviewRequest] = []
  var reviewPolicyPreviewError: (any Error)?
  var reviewPolicyStartResponse: ReviewsPolicyRunResponse?
  var reviewPolicyStartRequests: [ReviewsPolicyRunStartRequest] = []
  var reviewPolicyStartError: (any Error)?
  var reviewPolicyStatusResponse: ReviewsPolicyStatusResponse?
  var reviewPolicyStatusRequests: [ReviewsPolicyStatusRequest] = []
  var reviewPolicyStatusError: (any Error)?
  var reviewPolicyHistoryResponse: ReviewsPolicyHistoryResponse?
  var reviewPolicyHistoryRequests: [ReviewsPolicyHistoryRequest] = []
  var reviewPolicyHistoryError: (any Error)?
  var reviewPreviewRequests: [ReviewsFilesPreviewRequest] = []
  var reviewPatchRequests: [ReviewsFilesPatchRequest] = []
  var reviewPreviewDelay: Duration?, reviewPatchDelay: Duration?
  var reviewTimelineResponses: [String: [ReviewsTimelineResponse]] = [:]
  var reviewTimelineFetchedRequests: [ReviewsTimelineRequest] = []
  var reviewTimelineFetchHook: (@Sendable (String) async -> Void)?
  var reviewTimelineErrors: [String: any Error] = [:]
  var codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  var codexRunsDelaysBySessionID: [String: Duration] = [:]
  var resolvedAcpSnapshotsByAgentID: [String: AcpAgentSnapshot] = [:]
  var acpInspectResponsesBySessionID: [String: [AcpAgentInspectResponse]] = [:]
  var acpTranscriptResponsesBySessionID: [String: AcpTranscriptResponse] = [:]
  var codexTranscriptResponsesBySessionID: [String: CodexTranscriptResponse] = [:]
  var acpInspectError: (any Error)?
  var acpTranscriptErrorsBySessionID: [String: any Error] = [:]
  var agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:]
  var agentTuisDelaysBySessionID: [String: Duration] = [:]
  var agentTuiInputErrorsByID: [String: any Error] = [:]
  var agentTuiResizeErrorsByID: [String: any Error] = [:]
  var agentTuiStopErrorsByID: [String: any Error] = [:]
  var agentTuiReadErrorsByID: [String: any Error] = [:]
  var agentTuiInputResponsesByID: [String: [AgentTuiSnapshot]] = [:]
  var agentTuiReadSnapshotsByID: [String: [AgentTuiSnapshot]] = [:]
  var codexStartError: (any Error)?
  var queuedCodexStartErrors: [any Error] = []
  var acpStartError: (any Error)?
  var queuedAcpStartErrors: [any Error] = []
  var agentTuiStartError: (any Error)?
  var hostBridgeReconfigureError: (any Error)?
  var hostBridgeStatusReport = BridgeStatusReport(running: false)
  var globalStreamEvents: [DaemonPushEvent] = []
  var globalStreamError: (any Error)?
  var globalStreamErrorRemainingUses: Int?
  var sessionStreamEventsBySessionID: [String: [DaemonPushEvent]] = [:]
  var sessionStreamErrorsBySessionID: [String: any Error] = [:]
  var recordedShutdownCallCount = 0
  var recordedHealthCallCount = 0
  var recordedTransportLatencyCallCount = 0
  var recordedDiagnosticsCallCount = 0
  var recordedProjectsCallCount = 0
  var recordedSessionsCallCount = 0
  var readCallCountsByKey: [String: Int] = [:]
  var acpInspectCallCountsBySessionID: [String: Int] = [:]
  var acpTranscriptCallCountsBySessionID: [String: Int] = [:]
  var codexTranscriptCallCountsBySessionID: [String: Int] = [:]
  var sessionDetailCallCountsBySessionID: [String: Int] = [:]
  var timelineCallCountsBySessionID: [String: Int] = [:]
  var timelineWindowCallCountsBySessionID: [String: Int] = [:]
  var acpTranscriptDelaysBySessionID: [String: Duration] = [:]

  init(detail: SessionDetail = PreviewFixtures.detail) {
    detailStorage = detail
  }

}

@MainActor
func selectedActionStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.summary.sessionId)
  clearRecordedCallsIfNeeded(for: client)
  return store
}
