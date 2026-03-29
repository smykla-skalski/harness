import Foundation

public final class PreviewMonitorClient: MonitorClientProtocol, @unchecked Sendable {
  public struct Fixtures: Sendable {
    let health: HealthResponse
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let detail: SessionDetail?
    let timeline: [TimelineEntry]
    let readySessionID: String?

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
      readySessionID: PreviewFixtures.summary.sessionId
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
      readySessionID: nil
    )
  }

  private let fixtures: Fixtures

  public init(fixtures: Fixtures) {
    self.fixtures = fixtures
  }

  public convenience init() {
    self.init(fixtures: .populated)
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
        installed: !fixtures.sessions.isEmpty,
        label: "io.harness.monitor.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
      ),
      workspace: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        cacheRoot: "/Users/example/Library/Application Support/harness/daemon/cache/projects",
        cacheEntryCount: fixtures.sessions.isEmpty ? 0 : 4,
        lastEvent: lastEvent
      ),
      recentEvents: recentEvents
    )
  }

  public func projects() async throws -> [ProjectSummary] {
    fixtures.projects
  }

  public func sessions() async throws -> [SessionSummary] {
    fixtures.sessions
  }

  public func sessionDetail(id _: String) async throws -> SessionDetail {
    guard let detail = fixtures.detail else {
      throw MonitorAPIError.server(code: 404, message: "No preview session detail available.")
    }
    return detail
  }

  public func timeline(sessionID _: String) async throws -> [TimelineEntry] {
    fixtures.timeline
  }

  public func globalStream() -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        StreamEvent(
          event: "ready",
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: nil,
          payload: .object([:])
        )
      )
      continuation.finish()
    }
  }

  public func sessionStream(sessionID _: String) -> AsyncThrowingStream<StreamEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        StreamEvent(
          event: "ready",
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: fixtures.readySessionID,
          payload: .object([:])
        )
      )
      continuation.finish()
    }
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

  public func observeSession(
    sessionID _: String,
    request _: ObserveSessionRequest
  ) async throws -> SessionDetail {
    try await sessionDetail(id: "")
  }
}

public actor PreviewDaemonController: DaemonControlling {
  public enum Mode: Sendable {
    case populated
    case empty
  }

  private let client: PreviewMonitorClient
  private let statusReport: DaemonStatusReport

  public init(mode: Mode = .populated) {
    let fixtures = mode == .empty ? PreviewMonitorClient.Fixtures.empty : .populated
    self.client = PreviewMonitorClient(fixtures: fixtures)
    self.statusReport = DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: mode == .populated,
        label: "io.harness.monitor.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
      ),
      projectCount: fixtures.projects.count,
      sessionCount: fixtures.sessions.count,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        cacheRoot: "/Users/example/Library/Application Support/harness/daemon/cache/projects",
        cacheEntryCount: mode == .populated ? 4 : 0,
        lastEvent: mode == .populated
          ? DaemonAuditEvent(
            recordedAt: "2026-03-28T14:18:00Z",
            level: "info",
            message: "indexed session sess-monitor"
          ) : nil
      )
    )
  }

  public func bootstrapClient() async throws -> any MonitorClientProtocol {
    client
  }

  public func startDaemonClient() async throws -> any MonitorClientProtocol {
    client
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    statusReport
  }

  public func installLaunchAgent() async throws -> String {
    "/Users/example/Library/LaunchAgents/io.harness.monitor.daemon.plist"
  }

  public func removeLaunchAgent() async throws -> String {
    "removed"
  }
}
