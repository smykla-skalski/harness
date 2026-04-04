import Foundation

@testable import HarnessMonitorKit

actor RecordingDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var launchAgentInstalled: Bool
  private var lastEventMessage = "daemon ready"

  init(
    client: any HarnessMonitorClientProtocol = PreviewHarnessClient(),
    launchAgentInstalled: Bool = true
  ) {
    self.client = client
    self.launchAgentInstalled = launchAgentInstalled
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func startDaemonClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    lastEventMessage = "daemon stopped"
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: launchAgentInstalled,
        loaded: launchAgentInstalled,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: launchAgentInstalled ? "running" : nil,
        pid: launchAgentInstalled ? 4_242 : nil,
        lastExitStatus: launchAgentInstalled ? 0 : nil
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        cacheRoot: "/tmp/harness/daemon/cache/projects",
        cacheEntryCount: 2,
        lastEvent: DaemonAuditEvent(
          recordedAt: "2026-03-28T14:00:00Z",
          level: "info",
          message: lastEventMessage
        )
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    launchAgentInstalled = true
    lastEventMessage = "launch agent installed"
    return "/tmp/io.harness.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    launchAgentInstalled = false
    lastEventMessage = "launch agent removed"
    return "removed"
  }
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
    case createTask(
      sessionID: String,
      title: String,
      context: String?,
      severity: TaskSeverity,
      actor: String
    )
    case endSession(sessionID: String, actor: String)
    case observeSession(sessionID: String, actor: String)
    case removeAgent(sessionID: String, agentID: String, actor: String)
    case sendSignal(sessionID: String, agentID: String, command: String, actor: String)
    case transferLeader(sessionID: String, newLeaderID: String, reason: String?, actor: String)
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
  private var _diagnosticsDelay: Duration?
  private var _mutationDelay: Duration?
  private var _projectSummaries: [ProjectSummary]?
  private var _sessionSummaries: [SessionSummary]?
  private var _sessionDetailsByID: [String: SessionDetail] = [:]
  private var _detailDelays: [String: Duration] = [:]
  private var _timelinesBySessionID: [String: [TimelineEntry]] = [:]
  private var _timelineDelays: [String: Duration] = [:]
  private var _globalStreamEvents: [DaemonPushEvent] = []
  private var _globalStreamError: (any Error)?
  private var _sessionStreamEventsByID: [String: [DaemonPushEvent]] = [:]
  private var _sessionStreamErrorsByID: [String: any Error] = [:]
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
      typealias ProjectFixture = (
        name: String,
        projectDir: String?,
        contextRoot: String,
        activeSessionCount: Int,
        totalSessionCount: Int
      )

      var projectsByID: [String: ProjectFixture] = [:]
      var orderedProjectIDs: [String] = []

      for summary in summaries {
        if projectsByID[summary.projectId] == nil {
          orderedProjectIDs.append(summary.projectId)
          projectsByID[summary.projectId] = (
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

  func configuredHealthDelay() -> Duration? { lock.withLock { _healthDelay } }
  func configuredTransportLatencyMs() -> Int? { lock.withLock { _transportLatencyMs } }
  func configuredDiagnosticsDelay() -> Duration? { lock.withLock { _diagnosticsDelay } }
  func configuredMutationDelay() -> Duration? { lock.withLock { _mutationDelay } }
  func configuredProjects() -> [ProjectSummary]? { lock.withLock { _projectSummaries } }
  func configuredSessions() -> [SessionSummary]? { lock.withLock { _sessionSummaries } }
  func configuredSessionDetail(id: String) -> SessionDetail? { lock.withLock { _sessionDetailsByID[id] } }
  func configuredDetailDelay(for sessionID: String) -> Duration? { lock.withLock { _detailDelays[sessionID] } }
  func configuredTimeline(for sessionID: String) -> [TimelineEntry]? { lock.withLock { _timelinesBySessionID[sessionID] } }
  func configuredTimelineDelay(for sessionID: String) -> Duration? { lock.withLock { _timelineDelays[sessionID] } }
  func configuredGlobalStreamEvents() -> [DaemonPushEvent] { lock.withLock { _globalStreamEvents } }
  func configuredGlobalStreamError() -> (any Error)? { lock.withLock { _globalStreamError } }
  func configuredSessionStreamEvents(for sessionID: String) -> [DaemonPushEvent] { lock.withLock { _sessionStreamEventsByID[sessionID] ?? [] } }
  func configuredSessionStreamError(for sessionID: String) -> (any Error)? { lock.withLock { _sessionStreamErrorsByID[sessionID] } }

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
}

actor FailingDaemonController: DaemonControlling {
  private let bootstrapError: (any Error)?
  private let actionError: (any Error)?

  init(
    bootstrapError: (any Error)? = nil,
    actionError: (any Error)? = nil
  ) {
    self.bootstrapError = bootstrapError
    self.actionError = actionError
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewHarnessClient()
  }

  func startDaemonClient() async throws -> any HarnessMonitorClientProtocol {
    if let bootstrapError {
      throw bootstrapError
    }
    return PreviewHarnessClient()
  }

  func stopDaemon() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    throw DaemonControlError.manifestMissing
  }

  func installLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "/tmp/test.plist"
  }

  func removeLaunchAgent() async throws -> String {
    if let actionError {
      throw actionError
    }
    return "removed"
  }
}

final class FailingHarnessClient: HarnessMonitorClientProtocol, @unchecked Sendable {
  private let error: any Error

  init(error: any Error = HarnessMonitorAPIError.server(code: 500, message: "internal error")) {
    self.error = error
  }

  func health() async throws -> HealthResponse { throw error }
  func diagnostics() async throws -> DaemonDiagnosticsReport { throw error }
  func stopDaemon() async throws -> DaemonControlResponse { throw error }
  func projects() async throws -> [ProjectSummary] { throw error }
  func sessions() async throws -> [SessionSummary] { throw error }
  func sessionDetail(id _: String) async throws -> SessionDetail { throw error }
  func timeline(sessionID _: String) async throws -> [TimelineEntry] { throw error }

  nonisolated func globalStream() -> AsyncThrowingStream<DaemonPushEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  nonisolated func sessionStream(sessionID _: String) -> AsyncThrowingStream<DaemonPushEvent, Error> {
    AsyncThrowingStream { $0.finish(throwing: self.error) }
  }

  func createTask(sessionID _: String, request _: TaskCreateRequest) async throws -> SessionDetail {
    throw error
  }

  func assignTask(
    sessionID _: String, taskID _: String, request _: TaskAssignRequest
  ) async throws -> SessionDetail { throw error }

  func updateTask(
    sessionID _: String, taskID _: String, request _: TaskUpdateRequest
  ) async throws -> SessionDetail { throw error }

  func checkpointTask(
    sessionID _: String, taskID _: String, request _: TaskCheckpointRequest
  ) async throws -> SessionDetail { throw error }

  func changeRole(
    sessionID _: String, agentID _: String, request _: RoleChangeRequest
  ) async throws -> SessionDetail { throw error }

  func removeAgent(
    sessionID _: String, agentID _: String, request _: AgentRemoveRequest
  ) async throws -> SessionDetail { throw error }

  func transferLeader(
    sessionID _: String, request _: LeaderTransferRequest
  ) async throws -> SessionDetail { throw error }

  func endSession(
    sessionID _: String, request _: SessionEndRequest
  ) async throws -> SessionDetail { throw error }

  func sendSignal(
    sessionID _: String, request _: SignalSendRequest
  ) async throws -> SessionDetail { throw error }

  func observeSession(
    sessionID _: String, request _: ObserveSessionRequest
  ) async throws -> SessionDetail { throw error }
}

@MainActor
func makeBootstrappedStore(
  client: any HarnessMonitorClientProtocol = RecordingHarnessClient()
) async -> HarnessMonitorStore {
  let daemon = RecordingDaemonController(client: client)
  let store = HarnessMonitorStore(daemonController: daemon)
  await store.bootstrap()
  return store
}
