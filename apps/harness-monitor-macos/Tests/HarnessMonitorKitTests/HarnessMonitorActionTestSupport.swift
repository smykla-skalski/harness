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
    case sendAgentTuiInput(tuiID: String, input: AgentTuiInput)
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
    let traceContext = HarnessMonitorTelemetry.shared.traceContext()
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
