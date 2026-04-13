import Foundation

@testable import HarnessMonitorKit

private struct ProjectFixture {
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

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var _detail: SessionDetail
  private var _healthDelay: Duration?
  private var _transportLatencyMs: Int?
  private var _transportLatencyError: (any Error)?
  private var _diagnosticsDelay: Duration?
  private var _mutationDelay: Duration?
  private var _projectSummaries: [ProjectSummary]?
  private var _sessionSummaries: [SessionSummary]?
  private var _sessionDetailsByID: [String: SessionDetail] = [:]
  private var _detailDelays: [String: Duration] = [:]
  private var _sessionDetailErrorsByID: [String: any Error] = [:]
  private var _sessionDetailScopesByID: [String: [String?]] = [:]
  private var _timelinesBySessionID: [String: [TimelineEntry]] = [:]
  private var _timelineScopesBySessionID: [String: [TimelineScope]] = [:]
  private var _timelineBatchesBySessionID: [String: [[TimelineEntry]]] = [:]
  private var _timelineDelays: [String: Duration] = [:]
  private var _timelineBatchDelaysBySessionID: [String: Duration] = [:]
  private var _timelineErrorsByID: [String: any Error] = [:]
  private var _codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
  private var _agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:]
  private var _agentTuiInputResponsesByID: [String: [AgentTuiSnapshot]] = [:]
  private var _agentTuiReadSnapshotsByID: [String: [AgentTuiSnapshot]] = [:]
  private var _codexStartError: (any Error)?
  private var _queuedCodexStartErrors: [any Error] = []
  private var _agentTuiStartError: (any Error)?
  private var _hostBridgeReconfigureError: (any Error)?
  private var _hostBridgeStatusReport = BridgeStatusReport(running: false)
  private var _globalStreamEvents: [DaemonPushEvent] = []
  private var _globalStreamError: (any Error)?
  private var _sessionStreamEventsByID: [String: [DaemonPushEvent]] = [:]
  private var _sessionStreamErrorsByID: [String: any Error] = [:]
  private var _shutdownCallCount = 0
  private var _healthCallCount = 0
  private var _transportLatencyCallCount = 0
  private var _diagnosticsCallCount = 0
  private var _projectsCallCount = 0
  private var _sessionsCallCount = 0
  private var _sessionDetailCallCounts: [String: Int] = [:]
  private var _timelineCallCounts: [String: Int] = [:]

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
