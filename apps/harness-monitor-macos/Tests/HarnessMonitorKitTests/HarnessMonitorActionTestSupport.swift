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
  }

  let lock = NSLock()
  var _calls: [Call] = []
  var _detail: SessionDetail
  var _healthDelay: Duration?
  var _transportLatencyMs: Int?
  var _transportLatencyError: (any Error)?
  var _diagnosticsDelay: Duration?
  var _mutationDelay: Duration?
  var _projectSummaries: [ProjectSummary]?
  var _sessionSummaries: [SessionSummary]?
  var _sessionDetailsByID: [String: SessionDetail] = [:]
  var _detailDelays: [String: Duration] = [:]
  var _sessionDetailErrorsByID: [String: any Error] = [:]
  var _sessionDetailScopesByID: [String: [String?]] = [:]
  var _timelinesBySessionID: [String: [TimelineEntry]] = [:]
  var _timelineScopesByID: [String: [TimelineScope]] = [:]
  var _timelineBatchesBySessionID: [String: [[TimelineEntry]]] = [:]
  var _timelineDelays: [String: Duration] = [:]
  var _timelineBatchDelaysBySessionID: [String: Duration] = [:]
  var _timelineErrorsByID: [String: any Error] = [:]
  var _codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  var _agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:]
  var _agentTuiInputResponsesByID: [String: [AgentTuiSnapshot]] = [:]
  var _agentTuiReadSnapshotsByID: [String: [AgentTuiSnapshot]] = [:]
  var _codexStartError: (any Error)?
  var _queuedCodexStartErrors: [any Error] = []
  var _agentTuiStartError: (any Error)?
  var _hostBridgeReconfigureError: (any Error)?
  var _hostBridgeStatusReport = BridgeStatusReport(running: false)
  var _globalStreamEvents: [DaemonPushEvent] = []
  var _globalStreamError: (any Error)?
  var _sessionStreamEventsByID: [String: [DaemonPushEvent]] = [:]
  var _sessionStreamErrorsByID: [String: any Error] = [:]
  var _shutdownCallCount = 0
  var _healthCallCount = 0
  var _transportLatencyCallCount = 0
  var _diagnosticsCallCount = 0
  var _projectsCallCount = 0
  var _sessionsCallCount = 0
  var _sessionDetailCallCounts: [String: Int] = [:]
  var _timelineCallCounts: [String: Int] = [:]

  var calls: [Call] {
    get { lock.withLock { _calls } }
    set { lock.withLock { _calls = newValue } }
  }

  var detail: SessionDetail {
    get { lock.withLock { _detail } }
    set { lock.withLock { _detail = newValue } }
  }

  init(detail: SessionDetail = PreviewFixtures.detail) {
    self._detail = detail
  }
}
