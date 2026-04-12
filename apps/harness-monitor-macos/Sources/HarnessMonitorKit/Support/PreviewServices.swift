import Foundation

actor PreviewHostBridgeState {
  struct ManifestState: Sendable {
    let sandboxed: Bool
    let hostBridge: HostBridgeManifest
  }

  private var bridgeStatus: BridgeStatusReport?
  private let reconfigureBehavior: PreviewHostBridgeReconfigureBehavior

  init(override hostBridgeOverride: PreviewHostBridgeOverride?) {
    bridgeStatus = hostBridgeOverride?.bridgeStatus
    reconfigureBehavior = hostBridgeOverride?.reconfigureBehavior ?? .unsupported
  }

  func manifestState() -> ManifestState {
    guard let bridgeStatus else {
      return ManifestState(sandboxed: false, hostBridge: HostBridgeManifest())
    }
    return ManifestState(
      sandboxed: true,
      hostBridge: bridgeStatus.hostBridgeManifest
    )
  }

  func reconfigure(request: HostBridgeReconfigureRequest) throws -> BridgeStatusReport {
    guard var bridgeStatus else {
      throw HarnessMonitorAPIError.server(code: 501, message: "Host bridge unavailable.")
    }

    switch reconfigureBehavior {
    case .unsupported:
      throw HarnessMonitorAPIError.server(code: 501, message: "Host bridge unavailable.")
    case .missingRoute:
      throw HarnessMonitorAPIError.server(code: 404, message: "Route not found.")
    case .bridgeStopped:
      throw HarnessMonitorAPIError.server(code: 400, message: "bridge is not running")
    case .apply:
      var capabilities = bridgeStatus.capabilities
      for capability in request.enable {
        capabilities[capability] = previewHostBridgeCapabilityManifest(
          capability: capability,
          existing: capabilities[capability]
        )
      }
      for capability in request.disable {
        capabilities.removeValue(forKey: capability)
      }

      bridgeStatus = BridgeStatusReport(
        running: bridgeStatus.running,
        socketPath: bridgeStatus.socketPath,
        pid: bridgeStatus.pid,
        startedAt: bridgeStatus.startedAt,
        uptimeSeconds: bridgeStatus.uptimeSeconds,
        capabilities: capabilities
      )
      self.bridgeStatus = bridgeStatus
      return bridgeStatus
    }
  }

  private func previewHostBridgeCapabilityManifest(
    capability: String,
    existing: HostBridgeCapabilityManifest?
  ) -> HostBridgeCapabilityManifest {
    if let existing {
      return HostBridgeCapabilityManifest(
        enabled: true,
        healthy: true,
        transport: existing.transport,
        endpoint: existing.endpoint,
        metadata: existing.metadata
      )
    }

    switch capability {
    case "codex":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "websocket",
        endpoint: "ws://127.0.0.1:4545"
      )
    case "agent-tui":
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "unix",
        endpoint: "/tmp/harness-preview-bridge.sock",
        metadata: ["active_sessions": "0"]
      )
    default:
      return HostBridgeCapabilityManifest(
        healthy: true,
        transport: "preview"
      )
    }
  }
}

public actor PreviewVoiceCaptureService: VoiceCaptureProviding {
  public enum Behavior: Sendable {
    case transcript(String)
    case failure(any Error & Sendable)
  }

  public struct PreviewFailure: LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
      self.message = message
    }

    public var errorDescription: String? {
      message
    }
  }

  public static let defaultTranscript = "Preview voice input for Harness Monitor"

  private let behavior: Behavior
  private var continuation: VoiceCaptureEventStream.Continuation?
  private var emissionTask: Task<Void, Never>?

  public init(behavior: Behavior? = nil) {
    self.behavior = behavior ?? .transcript(Self.defaultTranscript)
  }

  public nonisolated func capture(configuration _: VoiceCaptureConfiguration)
    -> VoiceCaptureEventStream
  {
    VoiceCaptureEventStream { continuation in
      let task = Task {
        await self.start(continuation: continuation)
      }
      continuation.onTermination = { _ in
        task.cancel()
        Task {
          await self.stop()
        }
      }
    }
  }

  public func stop() async {
    emissionTask?.cancel()
    emissionTask = nil
    continuation?.yield(.state(.cancelled))
    continuation?.finish()
    continuation = nil
  }

  private func start(continuation: VoiceCaptureEventStream.Continuation) {
    emissionTask?.cancel()
    self.continuation = continuation
    continuation.yield(.state(.requestingPermission))
    continuation.yield(.state(.recording))
    emissionTask = Task {
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      switch behavior {
      case .transcript(let text):
        continuation.yield(
          .transcript(
            VoiceTranscriptSegment(
              sequence: 1,
              text: text,
              isFinal: true,
              startedAtSeconds: 0,
              durationSeconds: 0.5
            )
          )
        )
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        continuation.yield(.state(.finishing))
        continuation.finish()
      case .failure(let error):
        continuation.yield(.state(.failed))
        continuation.finish(throwing: error)
      }
    }
  }
}

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
    let agentTuisBySessionID: [String: [AgentTuiSnapshot]]
    let codexRunsBySessionID: [String: [CodexRunSnapshot]]

    public init(
      health: HealthResponse,
      projects: [ProjectSummary],
      sessions: [SessionSummary],
      detail: SessionDetail?,
      timeline: [TimelineEntry],
      readySessionID: String?,
      detailsBySessionID: [String: SessionDetail],
      coreDetailsBySessionID: [String: SessionDetail],
      timelinesBySessionID: [String: [TimelineEntry]],
      agentTuisBySessionID: [String: [AgentTuiSnapshot]] = [:],
      codexRunsBySessionID: [String: [CodexRunSnapshot]] = [:]
    ) {
      self.health = health
      self.projects = projects
      self.sessions = sessions
      self.detail = detail
      self.timeline = timeline
      self.readySessionID = readySessionID
      self.detailsBySessionID = detailsBySessionID
      self.coreDetailsBySessionID = coreDetailsBySessionID
      self.timelinesBySessionID = timelinesBySessionID
      self.agentTuisBySessionID = agentTuisBySessionID
      self.codexRunsBySessionID = codexRunsBySessionID
    }

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

    public static let toolbarCountRegression = Self(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 4242,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 42,
        worktreeCount: 5,
        sessionCount: 6
      ),
      projects: [
        ProjectSummary(
          projectId: "project-toolbar-harness",
          name: "harness",
          projectDir: "/Users/example/Projects/harness",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-harness",
          activeSessionCount: 2,
          totalSessionCount: 2,
          worktrees: [
            WorktreeSummary(
              checkoutId: "checkout-toolbar-harness",
              name: "session-title",
              checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
              contextRoot:
                "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-harness",
              activeSessionCount: 2,
              totalSessionCount: 2
            )
          ]
        ),
        ProjectSummary(
          projectId: "project-toolbar-kuma",
          name: "kuma",
          projectDir: "/Users/example/Projects/kuma",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-kuma",
          activeSessionCount: 1,
          totalSessionCount: 1,
          worktrees: [
            WorktreeSummary(
              checkoutId: "checkout-toolbar-kuma",
              name: "fix-motb",
              checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
              contextRoot:
                "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-kuma",
              activeSessionCount: 1,
              totalSessionCount: 1
            )
          ]
        ),
        ProjectSummary(
          projectId: "project-toolbar-orphan",
          name: "scratch",
          projectDir: "/Users/example/Projects/scratch",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-orphan",
          activeSessionCount: 0,
          totalSessionCount: 0,
          worktrees: [
            WorktreeSummary(
              checkoutId: "checkout-toolbar-orphan",
              name: "old-worktree",
              checkoutRoot: "/Users/example/Projects/scratch/.claude/worktrees/old-worktree",
              contextRoot:
                "/Users/example/Library/Application Support/harness/projects/checkout-toolbar-orphan",
              activeSessionCount: 0,
              totalSessionCount: 0
            )
          ]
        ),
      ],
      sessions: [
        SessionSummary(
          projectId: "project-toolbar-harness",
          projectName: "harness",
          projectDir: "/Users/example/Projects/harness",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-harness",
          checkoutId: "checkout-toolbar-harness",
          checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
          isWorktree: true,
          worktreeName: "session-title",
          sessionId: "sess-toolbar-harness-1",
          title: "Toolbar count fix",
          context: "Primary regression session",
          status: .active,
          createdAt: "2026-03-28T14:00:00Z",
          updatedAt: "2026-03-28T14:18:00Z",
          lastActivityAt: "2026-03-28T14:18:00Z",
          leaderId: "leader-harness",
          observeId: nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 2,
            activeAgentCount: 2,
            openTaskCount: 1,
            inProgressTaskCount: 1,
            blockedTaskCount: 0,
            completedTaskCount: 2
          )
        ),
        SessionSummary(
          projectId: "project-toolbar-harness",
          projectName: "harness",
          projectDir: "/Users/example/Projects/harness",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-harness",
          checkoutId: "checkout-toolbar-harness",
          checkoutRoot: "/Users/example/Projects/harness/.claude/worktrees/session-title",
          isWorktree: true,
          worktreeName: "session-title",
          sessionId: "sess-toolbar-harness-2",
          title: "Cache sweep validation",
          context: "Secondary regression session",
          status: .active,
          createdAt: "2026-03-28T14:01:00Z",
          updatedAt: "2026-03-28T14:19:00Z",
          lastActivityAt: "2026-03-28T14:19:00Z",
          leaderId: "leader-harness",
          observeId: nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 2,
            activeAgentCount: 1,
            openTaskCount: 2,
            inProgressTaskCount: 0,
            blockedTaskCount: 1,
            completedTaskCount: 1
          )
        ),
        SessionSummary(
          projectId: "project-toolbar-kuma",
          projectName: "kuma",
          projectDir: "/Users/example/Projects/kuma",
          contextRoot:
            "/Users/example/Library/Application Support/harness/projects/project-toolbar-kuma",
          checkoutId: "checkout-toolbar-kuma",
          checkoutRoot: "/Users/example/Projects/kuma/.claude/worktrees/fix-motb",
          isWorktree: true,
          worktreeName: "fix-motb",
          sessionId: "sess-toolbar-kuma-1",
          title: "Kuma validation",
          context: "Cross-project summary row",
          status: .active,
          createdAt: "2026-03-28T14:02:00Z",
          updatedAt: "2026-03-28T14:20:00Z",
          lastActivityAt: "2026-03-28T14:20:00Z",
          leaderId: "leader-kuma",
          observeId: nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 1,
            activeAgentCount: 1,
            openTaskCount: 1,
            inProgressTaskCount: 0,
            blockedTaskCount: 0,
            completedTaskCount: 3
          )
        ),
      ],
      detail: nil,
      timeline: [],
      readySessionID: nil,
      detailsBySessionID: [:],
      coreDetailsBySessionID: [:],
      timelinesBySessionID: [:]
    )

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
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
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
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    return updatedTui
  }

  public func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.resizeAgentTui(tuiID: tuiID, request: request) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    return updatedTui
  }

  public func stopAgentTui(tuiID: String) async throws -> AgentTuiSnapshot {
    try await performActionDelay()
    guard let updatedTui = await state.stopAgentTui(tuiID: tuiID) else {
      throw HarnessMonitorAPIError.server(code: 404, message: "Agent TUI unavailable.")
    }
    return updatedTui
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

private actor PreviewHarnessClientState {
  fileprivate static let mutationTimestamp = "2026-03-28T14:20:30Z"

  private var sessionSummaries: [SessionSummary]
  private var detailsBySessionID: [String: SessionDetail]
  private var coreDetailsBySessionID: [String: SessionDetail]
  private var timelinesBySessionID: [String: [TimelineEntry]]
  private var agentTuisBySessionID: [String: [AgentTuiSnapshot]]
  private var codexRunsBySessionID: [String: [CodexRunSnapshot]]
  private var nextAgentTuiSequence: Int
  private var nextCodexRunSequence: Int
  private let fallbackDetail: SessionDetail?
  private let fallbackTimeline: [TimelineEntry]

  init(fixtures: PreviewHarnessClient.Fixtures) {
    self.sessionSummaries = fixtures.sessions
    self.detailsBySessionID = fixtures.detailsBySessionID
    self.coreDetailsBySessionID = fixtures.coreDetailsBySessionID
    self.timelinesBySessionID = fixtures.timelinesBySessionID
    self.agentTuisBySessionID = fixtures.agentTuisBySessionID
    self.codexRunsBySessionID = fixtures.codexRunsBySessionID
    self.nextAgentTuiSequence = max(
      fixtures.agentTuisBySessionID.values.flatMap(\.self).count,
      0
    )
    self.nextCodexRunSequence = max(
      fixtures.codexRunsBySessionID.values.flatMap(\.self).count,
      0
    )
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

  func codexRuns(sessionID: String) -> [CodexRunSnapshot] {
    codexRunsBySessionID[sessionID] ?? []
  }

  func codexRun(runID: String) -> CodexRunSnapshot? {
    codexRunsBySessionID.values
      .flatMap(\.self)
      .first { run in
        run.runId == runID
      }
  }

  func startCodexRun(
    sessionID: String,
    request: CodexRunRequest
  ) -> CodexRunSnapshot {
    nextCodexRunSequence += 1
    let run = CodexRunSnapshot(
      runId: "preview-codex-run-\(nextCodexRunSequence)",
      sessionId: sessionID,
      projectDir: fallbackDetail?.session.projectDir ?? "/Users/example/Projects/harness",
      threadId: request.resumeThreadId,
      turnId: nil,
      mode: request.mode,
      status: .queued,
      prompt: request.prompt,
      latestSummary: request.actor.map { "Queued by \($0)" } ?? "Queued by preview",
      finalMessage: nil,
      error: nil,
      pendingApprovals: [],
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )
    var runs = codexRunsBySessionID[sessionID] ?? []
    runs.removeAll { $0.runId == run.runId }
    runs.insert(run, at: 0)
    codexRunsBySessionID[sessionID] = runs
    return run
  }

  func agentTuis(sessionID: String) -> [AgentTuiSnapshot] {
    agentTuisBySessionID[sessionID] ?? []
  }

  func agentTui(tuiID: String) -> AgentTuiSnapshot? {
    agentTuisBySessionID.values
      .flatMap(\.self)
      .first { tui in
        tui.tuiId == tuiID
      }
  }

  func startAgentTui(
    sessionID: String,
    request: AgentTuiStartRequest
  ) -> AgentTuiSnapshot {
    nextAgentTuiSequence += 1
    let runtimeTitle =
      AgentTuiRuntime(rawValue: request.runtime)?.title ?? request.runtime.capitalized
    let introText =
      if let prompt = request.prompt, !prompt.isEmpty {
        "\(runtimeTitle.lowercased())> \(prompt)"
      } else {
        "\(runtimeTitle.lowercased())> ready"
      }

    let snapshot = AgentTuiSnapshot(
      tuiId: "preview-agent-tui-\(nextAgentTuiSequence)",
      sessionId: sessionID,
      agentId: "preview-agent-\(nextAgentTuiSequence)",
      runtime: request.runtime,
      status: .running,
      argv: request.argv.isEmpty ? [request.runtime] : request.argv,
      projectDir: request.projectDir ?? fallbackDetail?.session.projectDir
        ?? "/Users/example/Projects/harness",
      size: AgentTuiSize(rows: request.rows, cols: request.cols),
      screen: AgentTuiScreenSnapshot(
        rows: request.rows,
        cols: request.cols,
        cursorRow: 1,
        cursorCol: min(max(introText.count + 1, 1), request.cols),
        text: introText
      ),
      transcriptPath:
        "/Users/example/Projects/harness/transcripts/preview-agent-tui-\(nextAgentTuiSequence).log",
      exitCode: nil,
      signal: nil,
      error: nil,
      createdAt: Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

    var sessionTuis = agentTuisBySessionID[sessionID] ?? []
    sessionTuis.insert(snapshot, at: 0)
    agentTuisBySessionID[sessionID] = sessionTuis
    return snapshot
  }

  func sendAgentTuiInput(
    tuiID: String,
    request: AgentTuiInputRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      let updatedText: String =
        switch request.input {
        case .text(let text), .paste(let text):
          [snapshot.screen.text, text].filter { !$0.isEmpty }.joined(separator: "\n")
        case .key(let key):
          [snapshot.screen.text, "[\(key.title)]"].filter { !$0.isEmpty }.joined(separator: "\n")
        case .control(let key):
          [snapshot.screen.text, "[Ctrl-\(String(key).uppercased())]"]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        case .rawBytesBase64:
          [snapshot.screen.text, "[raw bytes]"].filter { !$0.isEmpty }.joined(separator: "\n")
        }

      return snapshot.replacing(
        screen: snapshot.screen.replacing(
          rows: snapshot.screen.rows,
          cols: snapshot.screen.cols,
          text: updatedText
        )
      )
    }
  }

  func resizeAgentTui(
    tuiID: String,
    request: AgentTuiResizeRequest
  ) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        size: AgentTuiSize(rows: request.rows, cols: request.cols),
        screen: snapshot.screen.replacing(
          rows: request.rows,
          cols: request.cols,
          text: snapshot.screen.text
        )
      )
    }
  }

  func stopAgentTui(tuiID: String) -> AgentTuiSnapshot? {
    mutateAgentTui(tuiID: tuiID) { snapshot in
      snapshot.replacing(
        status: .stopped,
        exitCode: 0,
        signal: nil
      )
    }
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
    let agents = detail.agents
    let task = tasks[taskIndex]
    tasks[taskIndex] = task.replacingAssignment(
      status: .open,
      assignedTo: targetAgentID,
      queuePolicy: request.queuePolicy,
      queuedAt: agent.currentTaskId == nil ? nil : Self.mutationTimestamp,
      updatedAt: Self.mutationTimestamp
    )

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

  private func mutateAgentTui(
    tuiID: String,
    mutation: (AgentTuiSnapshot) -> AgentTuiSnapshot
  ) -> AgentTuiSnapshot? {
    for (sessionID, snapshots) in agentTuisBySessionID {
      guard let index = snapshots.firstIndex(where: { $0.tuiId == tuiID }) else {
        continue
      }

      var updatedSnapshots = snapshots
      updatedSnapshots[index] = mutation(snapshots[index])
      agentTuisBySessionID[sessionID] = updatedSnapshots
      return updatedSnapshots[index]
    }

    return nil
  }
}

extension WorkItem {
  fileprivate func replacingAssignment(
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

extension AgentTuiSnapshot {
  fileprivate func replacing(
    size: AgentTuiSize? = nil,
    screen: AgentTuiScreenSnapshot? = nil,
    status: AgentTuiStatus? = nil,
    exitCode: UInt32? = nil,
    signal: String? = nil
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: tuiId,
      sessionId: sessionId,
      agentId: agentId,
      runtime: runtime,
      status: status ?? self.status,
      argv: argv,
      projectDir: projectDir,
      size: size ?? self.size,
      screen: screen ?? self.screen,
      transcriptPath: transcriptPath,
      exitCode: exitCode ?? self.exitCode,
      signal: signal ?? self.signal,
      error: error,
      createdAt: createdAt,
      updatedAt: PreviewHarnessClientState.mutationTimestamp
    )
  }
}

extension AgentTuiScreenSnapshot {
  fileprivate func replacing(
    rows: Int,
    cols: Int,
    text: String
  ) -> AgentTuiScreenSnapshot {
    let lastLineLength =
      text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .last?
      .count ?? 0

    return AgentTuiScreenSnapshot(
      rows: rows,
      cols: cols,
      cursorRow: max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1),
      cursorCol: min(max(lastLineLength + 1, 1), cols),
      text: text
    )
  }
}

extension AgentRegistration {
  fileprivate func replacingCurrentTask(_ taskID: String) -> AgentRegistration {
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

extension SessionSummary {
  fileprivate func replacing(tasks: [WorkItem], agents: [AgentRegistration]) -> SessionSummary {
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

extension SessionMetrics {
  fileprivate init(tasks: [WorkItem], agents: [AgentRegistration]) {
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
