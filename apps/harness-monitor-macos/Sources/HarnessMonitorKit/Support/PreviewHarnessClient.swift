import Foundation

public final class PreviewHarnessClient: HarnessMonitorClientProtocol, Sendable {
  private let fixtures: Fixtures
  private let state: PreviewHarnessClientState
  private let isLaunchAgentInstalled: Bool
  private let hostBridgeState: PreviewHostBridgeState
  private let actionDelay: Duration?
  private let codexStartBehavior: PreviewCodexStartBehavior

  var readySessionID: String? {
    fixtures.readySessionID
  }

  public convenience init(
    fixtures: Fixtures,
    isLaunchAgentInstalled: Bool
  ) {
    self.init(
      fixtures: fixtures,
      isLaunchAgentInstalled: isLaunchAgentInstalled,
      hostBridgeState: PreviewHostBridgeState(override: nil),
      actionDelay: nil,
      codexStartBehavior: .unsupported
    )
  }

  init(
    fixtures: Fixtures,
    isLaunchAgentInstalled: Bool,
    hostBridgeState: PreviewHostBridgeState,
    actionDelay: Duration? = nil,
    codexStartBehavior: PreviewCodexStartBehavior = .unsupported
  ) {
    self.fixtures = fixtures
    self.state = PreviewHarnessClientState(fixtures: fixtures)
    self.isLaunchAgentInstalled = isLaunchAgentInstalled
    self.hostBridgeState = hostBridgeState
    self.actionDelay = actionDelay
    self.codexStartBehavior = codexStartBehavior
  }

  public convenience init() {
    self.init(
      fixtures: .populated,
      isLaunchAgentInstalled: true,
      hostBridgeState: PreviewHostBridgeState(override: nil),
      actionDelay: nil,
      codexStartBehavior: .unsupported
    )
  }

  private func performActionDelay() async throws {
    if let actionDelay {
      try await Task.sleep(for: actionDelay)
    }
  }

  public func health() async throws -> HealthResponse {
    fixtures.health
  }

  public func diagnostics() async throws -> DaemonDiagnosticsReport {
    let manifestState = await hostBridgeState.manifestState()
    let manifest = DaemonManifest(
      version: fixtures.health.version,
      pid: fixtures.health.pid,
      endpoint: fixtures.health.endpoint,
      startedAt: fixtures.health.startedAt,
      tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
      sandboxed: manifestState.sandboxed,
      hostBridge: manifestState.hostBridge
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

  public func reconfigureHostBridge(
    request: HostBridgeReconfigureRequest
  ) async throws -> BridgeStatusReport {
    try await hostBridgeState.reconfigure(request: request)
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

  public func codexRuns(sessionID: String) async throws -> CodexRunListResponse {
    CodexRunListResponse(runs: await state.codexRuns(sessionID: sessionID))
  }

  public func codexRun(runID: String) async throws -> CodexRunSnapshot {
    guard let run = await state.codexRun(runID: runID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Codex run unavailable.")
    }
    return run
  }

  public func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) async throws -> CodexRunSnapshot {
    try await performActionDelay()
    switch codexStartBehavior {
    case .unsupported:
      throw HarnessMonitorAPIError.server(code: 501, message: "Codex controller unavailable.")
    case .success:
      return await state.startCodexRun(sessionID: sessionID, request: request)
    case .unavailableRunningBridge:
      throw HarnessMonitorAPIError.server(code: 503, message: "codex-unavailable")
    }
  }

  public func createTask(
    sessionID _: String,
    request _: TaskCreateRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func assignTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskAssignRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func dropTask(
    sessionID: String,
    taskID: String,
    request: TaskDropRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await state.dropTask(sessionID: sessionID, taskID: taskID, request: request)
  }

  public func updateTaskQueuePolicy(
    sessionID _: String,
    taskID _: String,
    request _: TaskQueuePolicyRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func updateTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskUpdateRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func checkpointTask(
    sessionID _: String,
    taskID _: String,
    request _: TaskCheckpointRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func changeRole(
    sessionID _: String,
    agentID _: String,
    request _: RoleChangeRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func removeAgent(
    sessionID _: String,
    agentID _: String,
    request _: AgentRemoveRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func transferLeader(
    sessionID _: String,
    request _: LeaderTransferRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func endSession(
    sessionID _: String,
    request _: SessionEndRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func sendSignal(
    sessionID _: String,
    request _: SignalSendRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func cancelSignal(
    sessionID _: String,
    request _: SignalCancelRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func observeSession(
    sessionID _: String,
    request _: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await performActionDelay()
    return try await sessionDetail(id: "")
  }

  public func agentTuis(sessionID: String) async throws -> AgentTuiListResponse {
    AgentTuiListResponse(tuis: await state.agentTuis(sessionID: sessionID))
  }

  public func agentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    guard let tui = await state.agentTui(tuiID: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return tui
  }

  public func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    return await state.startAgentTui(sessionID: sessionID, request: request)
  }

  public func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.sendAgentTuiInput(tuiID: tuiID, request: request) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return updatedTui
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.resizeAgentTui(tuiID: tuiID, request: request) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return updatedTui
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.stopAgentTui(tuiID: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agents unavailable.")
    }
    return updatedTui
  }

  public func personas() async throws -> [AgentPersona] {
    [
      AgentPersona(
        identifier: "reviewer",
        name: "Reviewer",
        symbol: .sfSymbol(name: "checkmark.seal"),
        description: "Reviews code changes for correctness and style."
      ),
      AgentPersona(
        identifier: "architect",
        name: "Architect",
        symbol: .sfSymbol(name: "building.columns"),
        description: "Focuses on system design and architecture decisions."
      ),
    ]
  }

  public func logLevel() async throws -> LogLevelResponse {
    LogLevelResponse(
      level: HarnessMonitorLogger.defaultDaemonLogLevel,
      filter: HarnessMonitorLogger.defaultDaemonFilter
    )
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    LogLevelResponse(level: level, filter: "harness=\(level)")
  }
}
