import Foundation

public final class PreviewHarnessClient: HarnessMonitorClientProtocol, Sendable {
  public struct Fixtures: Sendable {
    let health: HealthResponse
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let detail: SessionDetail?
    let timeline: [TimelineEntry]
    let readySessionID: String?
    let detailsBySessionID: [String: SessionDetail]
    let coreDetailsBySessionID: [String: SessionDetail]
    let timelinesBySessionID: [String: [TimelineEntry]]

    public static let populated = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary],
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let taskDrop = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.taskDropSummary],
      detail: PreviewFixtures.taskDropDetail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.taskDropDetail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let dashboardLanding = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.projects,
      sessions: [PreviewFixtures.summary],
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: nil,
      detailsBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )

    public static let overflow: Self = {
      let sessions = PreviewFixtures.overflowSessions
      let detailsBySessionID = Dictionary(
        uniqueKeysWithValues: sessions.map { session in
          let detail =
            if session.sessionId == PreviewFixtures.summary.sessionId {
              PreviewFixtures.detail
            } else {
              PreviewFixtures.sessionDetail(session: session)
            }
          return (session.sessionId, detail)
        }
      )
      let timelinesBySessionID: [String: [TimelineEntry]] = Dictionary(
        uniqueKeysWithValues: sessions.map { session in
          let timeline: [TimelineEntry] =
            if session.sessionId == PreviewFixtures.summary.sessionId {
              PreviewFixtures.timeline
            } else {
              []
            }
          return (session.sessionId, timeline)
        }
      )
      return Self(
        health: HealthResponse(
          status: "ok",
          version: "14.5.0",
          pid: 4242,
          endpoint: "http://127.0.0.1:9999",
          startedAt: "2026-03-28T14:00:00Z",
          projectCount: 1,
          sessionCount: sessions.count
        ),
        projects: [
          ProjectSummary(
            projectId: PreviewFixtures.summary.projectId,
            name: PreviewFixtures.summary.projectName,
            projectDir: PreviewFixtures.summary.projectDir,
            contextRoot: PreviewFixtures.summary.contextRoot,
            activeSessionCount: sessions.filter { $0.status == .active }.count,
            totalSessionCount: sessions.count
          )
        ],
        sessions: sessions,
        detail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline,
        readySessionID: PreviewFixtures.summary.sessionId,
        detailsBySessionID: detailsBySessionID,
        coreDetailsBySessionID: [:],
        timelinesBySessionID: timelinesBySessionID
      )
    }()

    public static let signalRegression = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: PreviewFixtures.signalRegressionSessions.count
      ),
      projects: PreviewFixtures.signalRegressionProjects,
      sessions: PreviewFixtures.signalRegressionSessions,
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.detail,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId:
          PreviewFixtures.signalRegressionSecondaryDetail,
      ],
      coreDetailsBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.signalRegressionPrimaryCoreDetail,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId:
          PreviewFixtures.signalRegressionSecondaryCoreDetail,
      ],
      timelinesBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.timeline,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId: [],
      ]
    )

    public static let pagedTimeline = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: PreviewFixtures.signalRegressionSessions.count
      ),
      projects: PreviewFixtures.signalRegressionProjects,
      sessions: PreviewFixtures.signalRegressionSessions,
      detail: PreviewFixtures.detail,
      timeline: PreviewFixtures.pagedTimeline,
      readySessionID: PreviewFixtures.summary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.detail,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId:
          PreviewFixtures.signalRegressionSecondaryDetail,
      ],
      coreDetailsBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.signalRegressionPrimaryCoreDetail,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId:
          PreviewFixtures.signalRegressionSecondaryCoreDetail,
      ],
      timelinesBySessionID: [
        PreviewFixtures.summary.sessionId: PreviewFixtures.pagedTimeline,
        PreviewFixtures.signalRegressionSecondarySummary.sessionId: PreviewFixtures.timeline,
      ]
    )

    public static let singleAgent = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 1,
        sessionCount: 1
      ),
      projects: PreviewFixtures.singleAgentProjects,
      sessions: PreviewFixtures.singleAgentSessions,
      detail: PreviewFixtures.singleAgentDetail,
      timeline: [],
      readySessionID: PreviewFixtures.singleAgentSummary.sessionId,
      detailsBySessionID: [
        PreviewFixtures.singleAgentSummary.sessionId: PreviewFixtures.singleAgentDetail
      ],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

    public static let empty = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 0,
        sessionCount: 0
      ),
      projects: [],
      sessions: [],
      detail: nil,
      timeline: [],
      readySessionID: nil,
      detailsBySessionID: [:],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

    func detail(for sessionID: String, scope: String?) -> SessionDetail? {
      if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
        return coreDetail
      }

      if let scopedDetail = detailsBySessionID[sessionID] {
        return scopedDetail
      }

      return detail
    }

    func timeline(for sessionID: String) -> [TimelineEntry] {
      timelinesBySessionID[sessionID] ?? timeline
    }
  }

  private let fixtures: Fixtures
  private let state: PreviewHarnessClientState
  private let isLaunchAgentInstalled: Bool

  var readySessionID: String? {
    fixtures.readySessionID
  }

  public init(
    fixtures: Fixtures,
    isLaunchAgentInstalled: Bool
  ) {
    self.fixtures = fixtures
    self.state = PreviewHarnessClientState(fixtures: fixtures)
    self.isLaunchAgentInstalled = isLaunchAgentInstalled
  }

  public convenience init() {
    self.init(fixtures: .populated, isLaunchAgentInstalled: true)
  }

  public func health() async throws -> HealthResponse {
    fixtures.health
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    let manifest = DaemonManifest(
      version: fixtures.health.version,
      pid: fixtures.health.pid,
      endpoint: fixtures.health.endpoint,
      startedAt: fixtures.health.startedAt,
      tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
    )

    let lastEvent: DaemonAuditEvent?
    if let session = fixtures.sessions.first {
      lastEvent = DaemonAuditEvent(
        recordedAt: "2026-03-28T14:18:00Z",
        level: "info",
        message: "indexed session \(session.sessionId)"
      )
    } else {
      lastEvent = nil
    }
    let recentEvents = lastEvent.map { [$0] } ?? []
    return DaemonDiagnosticsReport(
      health: fixtures.health,
      manifest: manifest,
      launchAgent: LaunchAgentStatus(
        installed: isLaunchAgentInstalled,
        label: "io.harness.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
      ),
      workspace: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        databasePath: "/Users/example/Library/Application Support/harness/daemon/harness.db",
        databaseSizeBytes: fixtures.sessions.isEmpty ? 0 : 1_740_800,
        lastEvent: lastEvent
      ),
      recentEvents: recentEvents
    )
  }

  public func stopDaemon() async throws -> DaemonControlResponse {
    DaemonControlResponse(status: "stopping")
  }

  public func projects() async throws -> [ProjectSummary] {
    fixtures.projects
  }

  public func sessions() async throws -> [SessionSummary] {
    await state.sessions()
  }

  public func sessionDetail(id: String, scope: String?) async throws -> SessionDetail {
    guard let detail = await state.detail(for: id, scope: scope) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available."
      )
    }
    return detail
  }

  public func timeline(sessionID: String) async throws -> [TimelineEntry] {
    await state.timeline(for: sessionID)
  }

  public func createTask(
    sessionID _: String,
    request _: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func assignTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    try await state.dropTask(sessionID: sessionID, taskID: taskID, request: request)
  }

  public func updateTaskQueuePolicy(
    sessionID _: String,
    taskID _: String,
    request _: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func updateTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func checkpointTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func changeRole(
    sessionID _: String,
    agentID _: String,
    request _: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func removeAgent(
    sessionID _: String,
    agentID _: String,
    request _: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func transferLeader(
    sessionID _: String,
    request _: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func endSession(
    sessionID _: String,
    request _: SessionEndRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func sendSignal(
    sessionID _: String,
    request _: SignalSendRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func cancelSignal(
    sessionID _: String,
    request _: SignalCancelRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func observeSession(
    sessionID _: String,
    request _: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }

  public func logLevel() async throws -> LogLevelResponse {
    LogLevelResponse(level: "info", filter: "harness=info")
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    LogLevelResponse(level: level, filter: "harness=\(level)")
  }
}

private actor PreviewHarnessClientState {
  fileprivate static let mutationTimestamp = "2026-03-28T14:20:30Z"

  private var sessionSummaries: [SessionSummary]
  private var detailsBySessionID: [String: SessionDetail]
  private var coreDetailsBySessionID: [String: SessionDetail]
  private var timelinesBySessionID: [String: [TimelineEntry]]
  private let fallbackDetail: SessionDetail?
  private let fallbackTimeline: [TimelineEntry]

  init(fixtures: PreviewHarnessClient.Fixtures) {
    self.sessionSummaries = fixtures.sessions
    self.detailsBySessionID = fixtures.detailsBySessionID
    self.coreDetailsBySessionID = fixtures.coreDetailsBySessionID
    self.timelinesBySessionID = fixtures.timelinesBySessionID
    self.fallbackDetail = fixtures.detail
    self.fallbackTimeline = fixtures.timeline
  }

  func sessions() -> [SessionSummary] {
    sessionSummaries
  }

  func detail(for sessionID: String, scope: String?) -> SessionDetail? {
    if scope == "core", let coreDetail = coreDetailsBySessionID[sessionID] {
      return coreDetail
    }

    if let scopedDetail = detailsBySessionID[sessionID] {
      return scopedDetail
    }

    return fallbackDetail
  }

  func timeline(for sessionID: String) -> [TimelineEntry] {
    timelinesBySessionID[sessionID] ?? fallbackTimeline
  }

  func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) throws -> SessionDetail {
    guard let detail = detail(for: sessionID, scope: nil) else {
      throw HarnessMonitorAPIError.server(
        code: 404,
        message: "No preview session detail available."
      )
    }

    guard let taskIndex = detail.tasks.firstIndex(where: { $0.taskId == taskID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview task available.")
    }

    let targetAgentID: String
    switch request.target {
    case .agent(let agentID):
      targetAgentID = agentID
    }

    guard let agentIndex = detail.agents.firstIndex(where: { $0.agentId == targetAgentID }) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "No preview agent available.")
    }

    let agent = detail.agents[agentIndex]
    guard agent.role == .worker, agent.status == .active else {
      throw HarnessMonitorAPIError.server(code: 409, message: "Preview agent cannot take tasks.")
    }

    var tasks = detail.tasks
    var agents = detail.agents
    let task = tasks[taskIndex]
    let startsImmediately = agent.currentTaskId == nil

    tasks[taskIndex] = task.replacingAssignment(
      status: startsImmediately ? .inProgress : .open,
      assignedTo: targetAgentID,
      queuePolicy: request.queuePolicy,
      queuedAt: startsImmediately ? nil : Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    if startsImmediately {
      agents[agentIndex] = agent.replacingCurrentTask(taskID)
    }

    let updatedDetail = SessionDetail(
      session: detail.session.replacing(tasks: tasks, agents: agents),
      agents: agents,
      tasks: tasks,
      signals: detail.signals,
      observer: detail.observer,
      agentActivity: detail.agentActivity
    )

    detailsBySessionID[sessionID] = updatedDetail
    if coreDetailsBySessionID[sessionID] != nil {
      coreDetailsBySessionID[sessionID] = updatedDetail
    }
    if let sessionIndex = sessionSummaries.firstIndex(where: { $0.sessionId == sessionID }) {
      sessionSummaries[sessionIndex] = updatedDetail.session
    }
    return updatedDetail
  }
}

private extension WorkItem {
  func replacingAssignment(
    status: TaskStatus,
    assignedTo: String,
    queuePolicy: TaskQueuePolicy,
    queuedAt: String?,
    updatedAt: String
  ) -> WorkItem {
    WorkItem(
      taskId: taskId,
      title: title,
      context: context,
      severity: severity,
      status: status,
      assignedTo: assignedTo,
      queuePolicy: queuePolicy,
      queuedAt: queuedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      createdBy: createdBy,
      notes: notes,
      suggestedFix: suggestedFix,
      source: source,
      blockedReason: nil,
      completedAt: completedAt,
      checkpointSummary: checkpointSummary
    )
  }
}

private extension AgentRegistration {
  func replacingCurrentTask(_ taskID: String) -> AgentRegistration {
    AgentRegistration(
      agentId: agentId,
      name: name,
      runtime: runtime,
      role: role,
      capabilities: capabilities,
      joinedAt: joinedAt,
      updatedAt: updatedAt,
      status: status,
      agentSessionId: agentSessionId,
      lastActivityAt: lastActivityAt,
      currentTaskId: taskID,
      runtimeCapabilities: runtimeCapabilities
    )
  }
}

private extension SessionSummary {
  func replacing(tasks: [WorkItem], agents: [AgentRegistration]) -> SessionSummary {
    SessionSummary(
      projectId: projectId,
      projectName: projectName,
      projectDir: projectDir,
      contextRoot: contextRoot,
      checkoutId: checkoutId,
      checkoutRoot: checkoutRoot,
      isWorktree: isWorktree,
      worktreeName: worktreeName,
      sessionId: sessionId,
      title: title,
      context: context,
      status: status,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp,
      lastActivityAt: PreviewHarnessClientState.mutationTimestamp,
      leaderId: leaderId,
      observeId: observeId,
      pendingLeaderTransfer: pendingLeaderTransfer,
      metrics: SessionMetrics(tasks: tasks, agents: agents)
    )
  }
}

private extension SessionMetrics {
  init(tasks: [WorkItem], agents: [AgentRegistration]) {
    self.init(
      agentCount: agents.count,
      activeAgentCount: agents.filter { $0.status == .active }.count,
      openTaskCount: tasks.filter { $0.status == .open }.count,
      inProgressTaskCount: tasks.filter { $0.status == .inProgress }.count,
      blockedTaskCount: tasks.filter { $0.status == .blocked }.count,
      completedTaskCount: tasks.filter { $0.status == .done }.count
    )
  }
}
