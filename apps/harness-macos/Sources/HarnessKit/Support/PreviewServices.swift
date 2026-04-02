import Foundation

public final class PreviewHarnessClient: HarnessClientProtocol, Sendable {
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

    public static let overflow: Self = {
      let sessions = PreviewFixtures.overflowSessions
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
        readySessionID: PreviewFixtures.summary.sessionId
      )
    }()

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
  private let isLaunchAgentInstalled: Bool

  public init(
    fixtures: Fixtures,
    isLaunchAgentInstalled: Bool
  ) {
    self.fixtures = fixtures
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
      throw HarnessAPIError.server(code: 404, message: "No preview session detail available.")
    }
    return detail
  }

  public func timeline(sessionID _: String) async throws -> [TimelineEntry] {
    fixtures.timeline
  }

  public func globalStream() async -> AsyncThrowingStream<DaemonPushEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        .ready(recordedAt: "2026-03-28T14:00:00Z")
      )
      continuation.finish()
    }
  }

  public func sessionStream(sessionID _: String) async -> AsyncThrowingStream<DaemonPushEvent, Error> {
    AsyncThrowingStream { continuation in
      continuation.yield(
        .ready(
          recordedAt: "2026-03-28T14:00:00Z",
          sessionId: fixtures.readySessionID
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
    case overflow
    case empty
  }

  private let fixtures: PreviewHarnessClient.Fixtures
  private var isDaemonRunning: Bool
  private var isLaunchAgentInstalled: Bool

  public init(mode: Mode = .populated) {
    let fixtures =
      switch mode {
      case .populated:
        PreviewHarnessClient.Fixtures.populated
      case .overflow:
        PreviewHarnessClient.Fixtures.overflow
      case .empty:
        PreviewHarnessClient.Fixtures.empty
      }

    self.fixtures = fixtures
    self.isDaemonRunning = mode != .empty
    self.isLaunchAgentInstalled = mode != .empty
  }

  public func bootstrapClient() async throws -> any HarnessClientProtocol {
    guard isDaemonRunning else {
      throw DaemonControlError.daemonOffline
    }
    return makeClient()
  }

  public func startDaemonClient() async throws -> any HarnessClientProtocol {
    isDaemonRunning = true
    return makeClient()
  }

  public func daemonStatus() async throws -> DaemonStatusReport {
    makeStatusReport()
  }

  public func installLaunchAgent() async throws -> String {
    isLaunchAgentInstalled = true
    return Self.launchAgentPath
  }

  public func removeLaunchAgent() async throws -> String {
    isLaunchAgentInstalled = false
    return "removed"
  }

  private func makeClient() -> PreviewHarnessClient {
    PreviewHarnessClient(
      fixtures: fixtures,
      isLaunchAgentInstalled: isLaunchAgentInstalled
    )
  }

  private func makeStatusReport() -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: fixtures.health.version,
        pid: fixtures.health.pid,
        endpoint: fixtures.health.endpoint,
        startedAt: fixtures.health.startedAt,
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: isLaunchAgentInstalled,
        loaded: isDaemonRunning && isLaunchAgentInstalled,
        label: "io.harness.daemon",
        path: Self.launchAgentPath,
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: isDaemonRunning ? "running" : nil,
        pid: isDaemonRunning ? fixtures.health.pid : nil,
        lastExitStatus: isDaemonRunning ? 0 : nil
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
        cacheEntryCount: isDaemonRunning ? max(4, fixtures.sessions.count) : 0,
        lastEvent: makeLastEvent()
      )
    )
  }

  private func makeLastEvent() -> DaemonAuditEvent? {
    guard isDaemonRunning, let firstSession = fixtures.sessions.first else {
      return nil
    }

    return DaemonAuditEvent(
      recordedAt: "2026-03-28T14:18:00Z",
      level: "info",
      message: "indexed session \(firstSession.sessionId)"
    )
  }
}

private extension PreviewDaemonController {
  static let launchAgentPath = "/Users/example/Library/LaunchAgents/io.harness.daemon.plist"
}
