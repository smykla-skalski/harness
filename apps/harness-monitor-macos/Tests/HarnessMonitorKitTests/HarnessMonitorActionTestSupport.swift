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

  func recordedCalls() -> [Call] {
    calls
  }

  func configureHealthDelay(_ delay: Duration?) {
    lock.withLock {
      _healthDelay = delay
    }
  }

  func configureTransportLatencyMs(_ latencyMs: Int?) {
    lock.withLock {
      _transportLatencyMs = latencyMs
    }
  }

  func configureTransportLatencyError(_ error: (any Error)?) {
    lock.withLock {
      _transportLatencyError = error
    }
  }

  func configureDiagnosticsDelay(_ delay: Duration?) {
    lock.withLock {
      _diagnosticsDelay = delay
    }
  }

  func configureMutationDelay(_ delay: Duration?) {
    lock.withLock {
      _mutationDelay = delay
    }
  }

  func configureSessions(
    summaries: [SessionSummary],
    detailsByID: [String: SessionDetail],
    timelinesBySessionID: [String: [TimelineEntry]] = [:]
  ) {
    lock.withLock {
      var projectsByID: [String: ProjectFixture] = [:]
      var orderedProjectIDs: [String] = []

      for summary in summaries {
        if projectsByID[summary.projectId] == nil {
          orderedProjectIDs.append(summary.projectId)
          projectsByID[summary.projectId] = ProjectFixture(
            name: summary.projectName,
            projectDir: summary.projectDir,
            contextRoot: summary.contextRoot,
            activeSessionCount: 0,
            totalSessionCount: 0
          )
        }

        guard var project = projectsByID[summary.projectId] else {
          continue
        }
        project.totalSessionCount += 1
        if summary.status != .ended {
          project.activeSessionCount += 1
        }
        projectsByID[summary.projectId] = project
      }

      _projectSummaries = orderedProjectIDs.compactMap { projectID in
        guard let project = projectsByID[projectID] else {
          return nil
        }

        return ProjectSummary(
          projectId: projectID,
          name: project.name,
          projectDir: project.projectDir,
          contextRoot: project.contextRoot,
          activeSessionCount: project.activeSessionCount,
          totalSessionCount: project.totalSessionCount
        )
      }
      _sessionSummaries = summaries
      _sessionDetailsByID = detailsByID
      _timelinesBySessionID = timelinesBySessionID
    }
  }

  func configureDetailDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        _detailDelays[sessionID] = delay
      } else {
        _detailDelays.removeValue(forKey: sessionID)
      }
    }
  }

  func configureSessionDetailError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        _sessionDetailErrorsByID[sessionID] = error
      } else {
        _sessionDetailErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredSessionDetailError(for sessionID: String) -> (any Error)? {
    lock.withLock { _sessionDetailErrorsByID[sessionID] }
  }

  func configureTimelineError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        _timelineErrorsByID[sessionID] = error
      } else {
        _timelineErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredTimelineError(for sessionID: String) -> (any Error)? {
    lock.withLock { _timelineErrorsByID[sessionID] }
  }

  func configureTimelineDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        _timelineDelays[sessionID] = delay
      } else {
        _timelineDelays.removeValue(forKey: sessionID)
      }
    }
  }

  func configureGlobalStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil
  ) {
    lock.withLock {
      _globalStreamEvents = events
      _globalStreamError = error
    }
  }

  func configureSessionStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      _sessionStreamEventsByID[sessionID] = events
      if let error {
        _sessionStreamErrorsByID[sessionID] = error
      } else {
        _sessionStreamErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureCodexRuns(_ runs: [CodexRunSnapshot], for sessionID: String) {
    lock.withLock {
      _codexRunsBySessionID[sessionID] = runs
    }
  }

  func configureAgentTuis(_ tuis: [AgentTuiSnapshot], for sessionID: String) {
    lock.withLock {
      _agentTuisBySessionID[sessionID] = tuis
    }
  }

  func configureAgentTuiInputResponses(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      _agentTuiInputResponsesByID[tuiID] = snapshots
    }
  }

  func configureAgentTuiReadSnapshots(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      _agentTuiReadSnapshotsByID[tuiID] = snapshots
    }
  }

  func configureCodexStartError(_ error: (any Error)?) {
    lock.withLock {
      _codexStartError = error
      _queuedCodexStartErrors = []
    }
  }

  func configureCodexStartErrors(_ errors: [any Error]) {
    lock.withLock {
      _queuedCodexStartErrors = errors
      _codexStartError = nil
    }
  }

  func configureAgentTuiStartError(_ error: (any Error)?) {
    lock.withLock { _agentTuiStartError = error }
  }

  func configureHostBridgeReconfigureError(_ error: (any Error)?) {
    lock.withLock { _hostBridgeReconfigureError = error }
  }

  func configureHostBridgeStatusReport(_ report: BridgeStatusReport) {
    lock.withLock { _hostBridgeStatusReport = report }
  }

  func configuredCodexStartError() -> (any Error)? {
    lock.withLock { _codexStartError }
  }

  func dequeueConfiguredCodexStartError() -> (any Error)? {
    lock.withLock {
      guard let error = _queuedCodexStartErrors.first else {
        return _codexStartError
      }
      _queuedCodexStartErrors.removeFirst()
      return error
    }
  }

  func configuredAgentTuiStartError() -> (any Error)? {
    lock.withLock { _agentTuiStartError }
  }

  func configuredHostBridgeReconfigureError() -> (any Error)? {
    lock.withLock { _hostBridgeReconfigureError }
  }

  func configuredHostBridgeStatusReport() -> BridgeStatusReport {
    lock.withLock { _hostBridgeStatusReport }
  }

  func configuredHealthDelay() -> Duration? { lock.withLock { _healthDelay } }
  func configuredTransportLatencyMs() -> Int? { lock.withLock { _transportLatencyMs } }
  func configuredTransportLatencyError() -> (any Error)? {
    lock.withLock { _transportLatencyError }
  }
  func configuredDiagnosticsDelay() -> Duration? { lock.withLock { _diagnosticsDelay } }
  func configuredMutationDelay() -> Duration? { lock.withLock { _mutationDelay } }
  func configuredProjects() -> [ProjectSummary]? { lock.withLock { _projectSummaries } }
  func configuredSessions() -> [SessionSummary]? { lock.withLock { _sessionSummaries } }
  func configuredSessionDetail(id: String) -> SessionDetail? {
    lock.withLock { _sessionDetailsByID[id] }
  }
  func configuredDetailDelay(for sessionID: String) -> Duration? {
    lock.withLock { _detailDelays[sessionID] }
  }
  func sessionDetailScopes(for sessionID: String) -> [String?] {
    lock.withLock { _sessionDetailScopesByID[sessionID] ?? [] }
  }
  func configuredTimeline(for sessionID: String) -> [TimelineEntry]? {
    lock.withLock { _timelinesBySessionID[sessionID] }
  }
  func timelineScopes(for sessionID: String) -> [TimelineScope] {
    lock.withLock { _timelineScopesBySessionID[sessionID] ?? [] }
  }
  func configuredTimelineBatches(for sessionID: String) -> [[TimelineEntry]]? {
    lock.withLock { _timelineBatchesBySessionID[sessionID] }
  }
  func configuredTimelineDelay(for sessionID: String) -> Duration? {
    lock.withLock { _timelineDelays[sessionID] }
  }
  func configuredTimelineBatchDelay(for sessionID: String) -> Duration? {
    lock.withLock { _timelineBatchDelaysBySessionID[sessionID] }
  }
  func configuredCodexRuns(for sessionID: String) -> [CodexRunSnapshot] {
    lock.withLock { _codexRunsBySessionID[sessionID] ?? [] }
  }
  func configuredAgentTuis(for sessionID: String) -> [AgentTuiSnapshot] {
    lock.withLock { _agentTuisBySessionID[sessionID] ?? [] }
  }
  func configuredCodexRun(id runID: String) -> CodexRunSnapshot? {
    lock.withLock {
      _codexRunsBySessionID.values.flatMap(\.self).first { $0.runId == runID }
    }
  }
  func configuredAgentTui(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      _agentTuisBySessionID.values.flatMap(\.self).first { $0.tuiId == tuiID }
    }
  }
  func dequeueConfiguredAgentTuiInputResponse(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &_agentTuiInputResponsesByID,
        tuiID: tuiID
      )
    }
  }
  func dequeueConfiguredAgentTuiReadSnapshot(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &_agentTuiReadSnapshotsByID,
        tuiID: tuiID
      )
    }
  }
  func recordCodexRun(_ run: CodexRunSnapshot) {
    lock.withLock {
      var runs = _codexRunsBySessionID[run.sessionId] ?? []
      runs.removeAll { $0.runId == run.runId }
      runs.insert(run, at: 0)
      _codexRunsBySessionID[run.sessionId] = runs
    }
  }
  func recordAgentTui(_ tui: AgentTuiSnapshot) {
    lock.withLock {
      var tuis = _agentTuisBySessionID[tui.sessionId] ?? []
      tuis.removeAll { $0.tuiId == tui.tuiId }
      tuis.insert(tui, at: 0)
      _agentTuisBySessionID[tui.sessionId] = tuis
    }
  }
  func configuredGlobalStreamEvents() -> [DaemonPushEvent] { lock.withLock { _globalStreamEvents } }
  func configuredGlobalStreamError() -> (any Error)? { lock.withLock { _globalStreamError } }
  func configuredSessionStreamEvents(for sessionID: String) -> [DaemonPushEvent] {
    lock.withLock { _sessionStreamEventsByID[sessionID] ?? [] }
  }
  func configuredSessionStreamError(for sessionID: String) -> (any Error)? {
    lock.withLock { _sessionStreamErrorsByID[sessionID] }
  }
  func shutdownCallCount() -> Int { lock.withLock { _shutdownCallCount } }

  func recordReadCall(_ call: ReadCall) {
    lock.withLock {
      switch call {
      case .health:
        _healthCallCount += 1
      case .transportLatency:
        _transportLatencyCallCount += 1
      case .diagnostics:
        _diagnosticsCallCount += 1
      case .projects:
        _projectsCallCount += 1
      case .sessions:
        _sessionsCallCount += 1
      case .sessionDetail(let sessionID):
        _sessionDetailCallCounts[sessionID, default: 0] += 1
      case .timeline(let sessionID):
        _timelineCallCounts[sessionID, default: 0] += 1
      }
    }
  }

  func readCallCount(_ call: ReadCall) -> Int {
    lock.withLock {
      switch call {
      case .health:
        _healthCallCount
      case .transportLatency:
        _transportLatencyCallCount
      case .diagnostics:
        _diagnosticsCallCount
      case .projects:
        _projectsCallCount
      case .sessions:
        _sessionsCallCount
      case .sessionDetail(let sessionID):
        _sessionDetailCallCounts[sessionID, default: 0]
      case .timeline(let sessionID):
        _timelineCallCounts[sessionID, default: 0]
      }
    }
  }

  func recordSessionDetailScope(id: String, scope: String?) {
    lock.withLock {
      _sessionDetailScopesByID[id, default: []].append(scope)
    }
  }

  func configureTimelineBatches(
    _ batches: [[TimelineEntry]],
    batchDelay: Duration? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      _timelineBatchesBySessionID[sessionID] = batches
      if let batchDelay {
        _timelineBatchDelaysBySessionID[sessionID] = batchDelay
      } else {
        _timelineBatchDelaysBySessionID.removeValue(forKey: sessionID)
      }
      _timelinesBySessionID[sessionID] = batches.flatMap(\.self)
    }
  }

  func recordTimelineScope(sessionID: String, scope: TimelineScope) {
    lock.withLock {
      _timelineScopesBySessionID[sessionID, default: []].append(scope)
    }
  }

  func shutdown() async {
    lock.withLock {
      _shutdownCallCount += 1
    }
  }

  private func dequeueAgentTuiSnapshot(
    from storage: inout [String: [AgentTuiSnapshot]],
    tuiID: String
  ) -> AgentTuiSnapshot? {
    guard var snapshots = storage[tuiID], let snapshot = snapshots.first else {
      return nil
    }

    snapshots.removeFirst()
    if snapshots.isEmpty {
      storage.removeValue(forKey: tuiID)
    } else {
      storage[tuiID] = snapshots
    }

    var tuis = _agentTuisBySessionID[snapshot.sessionId] ?? []
    tuis.removeAll { $0.tuiId == snapshot.tuiId }
    tuis.insert(snapshot, at: 0)
    _agentTuisBySessionID[snapshot.sessionId] = tuis
    return snapshot
  }
}
