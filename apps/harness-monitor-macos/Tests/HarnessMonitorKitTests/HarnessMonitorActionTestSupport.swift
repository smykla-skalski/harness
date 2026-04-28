import Foundation

@testable import HarnessMonitorKit

struct ProjectFixture {
  let name: String
  let projectDir: String?
  let contextRoot: String
  var activeSessionCount: Int
  var totalSessionCount: Int
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
    case sendAgentTuiInput(tuiID: String, request: AgentTuiInputRequest)
    case resizeAgentTui(tuiID: String, rows: Int, cols: Int)
    case stopAgentTui(tuiID: String)
    case adoptSession(bookmarkID: String?, sessionRoot: URL)
    case startSession(projectDir: String, baseRef: String?)
    case endSession(sessionID: String, actor: String)
    case observeSession(sessionID: String, actor: String)
    case removeAgent(sessionID: String, agentID: String, actor: String)
    case resolveCodexApproval(
      runID: String,
      approvalID: String,
      decision: CodexApprovalDecision
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
    case sessionDetail(String)
    case timeline(String)
    case timelineWindow(String)
  }

  let lock = NSLock()
  var callsStorage: [Call] = []
  var detailStorage: SessionDetail
  var healthDelay: Duration?
  var transportLatencyMsValue: Int?
  var transportLatencyError: (any Error)?
  var diagnosticsDelay: Duration?
  var projectsDelay: Duration?
  var sessionsDelay: Duration?
  var queuedDiagnosticsErrors: [any Error] = []
  var queuedProjectsErrors: [any Error] = []
  var queuedSessionsErrors: [any Error] = []
  var mutationDelay: Duration?
  var projectSummariesStorage: [ProjectSummary]?
  var sessionSummariesStorage: [SessionSummary]?
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
  var codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  var codexRunsDelaysBySessionID: [String: Duration] = [:]
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
  var agentTuiStartError: (any Error)?
  var hostBridgeReconfigureError: (any Error)?
  var hostBridgeStatusReport = BridgeStatusReport(running: false)
  var globalStreamEvents: [DaemonPushEvent] = []
  var globalStreamError: (any Error)?
  var sessionStreamEventsBySessionID: [String: [DaemonPushEvent]] = [:]
  var sessionStreamErrorsBySessionID: [String: any Error] = [:]
  var recordedShutdownCallCount = 0
  var recordedHealthCallCount = 0
  var recordedTransportLatencyCallCount = 0
  var recordedDiagnosticsCallCount = 0
  var recordedProjectsCallCount = 0
  var recordedSessionsCallCount = 0
  var sessionDetailCallCountsBySessionID: [String: Int] = [:]
  var timelineCallCountsBySessionID: [String: Int] = [:]
  var timelineWindowCallCountsBySessionID: [String: Int] = [:]

  var calls: [Call] {
    get { lock.withLock { callsStorage } }
    set { lock.withLock { callsStorage = newValue } }
  }

  var detail: SessionDetail {
    get { lock.withLock { detailStorage } }
    set { lock.withLock { detailStorage = newValue } }
  }

  init(detail: SessionDetail = PreviewFixtures.detail) {
    detailStorage = detail
  }

  func recordActiveTraceContext(operation: String) {
    #if HARNESS_FEATURE_OTEL
      let traceContext = HarnessMonitorTelemetry.shared.traceContext()
    #else
      let traceContext: [String: String] = [:]
    #endif
    lock.withLock {
      recordedTraceContextsByOperation[operation, default: []].append(traceContext)
    }
  }

  func lastRecordedTraceContext(for operation: String) -> [String: String]? {
    lock.withLock {
      recordedTraceContextsByOperation[operation]?.last
    }
  }
}

@MainActor
func selectedActionStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.summary.sessionId)
  return store
}

func actorlessActionClient() -> RecordingHarnessClient {
  HarnessMonitorStoreSelectionTestSupport.configuredClient(
    summaries: [PreviewFixtures.emptyCockpitSummary],
    detailsByID: [
      PreviewFixtures.emptyCockpitSummary.sessionId: PreviewFixtures.emptyCockpitDetail
    ],
    detail: PreviewFixtures.emptyCockpitDetail
  )
}

@MainActor
func actorlessActionStore(client: RecordingHarnessClient) async -> HarnessMonitorStore {
  let store = await makeBootstrappedStore(client: client)
  await store.selectSession(PreviewFixtures.emptyCockpitSummary.sessionId)
  return store
}

let expectedLeaderlessActionMessage = """
  Leader-only actions are unavailable until a real leader joins this session.
  Observe, end session, and task controls remain available.
  """
