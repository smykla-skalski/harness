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
  var queuedTaskBoardProjectsErrors: [any Error] = []
  var queuedDeliverTaskBoardDispatchErrors: [any Error] = []
  var heldTaskBoardDispatchItemIDs: [String] = []
  var taskBoardDispatchFailureMessages: [String: String] = [:]
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
  var taskBoardWorkingCopiesStorage: [WorkingCopyListEntry] = []
  var taskBoardCreateError: (any Error)?
  var taskBoardUpdateError: (any Error)?
  var taskBoardItemRevisionsStorage: [String: Int64] = [:]
  var taskBoardItemsChangeSeqStorage: Int64 = 0
  /// Ordered newest-first per item id; the first entry is the current decision.
  var taskBoardTriageDecisionsStorage: [String: [TaskBoardTriageDecisionRecord]] = [:]
  var taskBoardTriageOverridesStorage: [String: TaskBoardTriageOverride] = [:]
  var taskBoardTriageOverrideError: (any Error)?
  var triageOverrideErrorRemainingUses = 0
  var taskBoardTriageOverrideItemsAfterError: [TaskBoardItem]?
  var taskBoardTriageOverrideSetRequests: [TaskBoardSetTriageOverrideRequest] = []
  var taskBoardTriageOverrideClearRequests: [TaskBoardClearTriageOverrideRequest] = []
  var taskBoardTriageRuleSetDraftStorage: TriageRuleSetDraft?
  var activeTriageRuleSetRevisionStorage: Int64?
  var taskBoardTriageRuleSetRevisionsStorage: [TriageRuleSetRevisionSummary] = []
  var taskBoardTriageRuleSetAuditStorage: [TriageRuleSetAuditEntry] = []
  var taskBoardTriageRulesSaveDraftRequests: [TaskBoardSaveTriageRulesDraftRequest] = []
  var taskBoardTriageRulesActivateRequests: [TaskBoardActivateTriageRulesRequest] = []
  var taskBoardTriageRulesError: (any Error)?
  var taskBoardTriageRulesErrorRemainingUses = 0
  var taskBoardPositionError: (any Error)?
  var taskBoardPositionErrorRemainingUses = 0
  var taskBoardPositionItemsAfterError: [TaskBoardItem]?
  var taskUpdateError: (any Error)?
  var taskBoardRuntimeConfigError: (any Error)?
  var taskBoardOrchestratorSettingsError: (any Error)?
  var taskBoardOrchestratorSettingsResponse: TaskBoardOrchestratorSettings?
  let orchestratorSettingsMutationGate =
    RecordingTaskBoardOrchestratorSettingsMutationGate()
  var taskBoardGitHubTokensSyncError: (any Error)?
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
