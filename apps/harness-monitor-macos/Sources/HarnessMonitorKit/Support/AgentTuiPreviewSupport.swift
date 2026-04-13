import Foundation

public struct AgentTuiSnapshotSpec {
  public let agentID: String
  public let runtime: AgentTuiRuntime
  public let status: AgentTuiStatus
  public let size: AgentTuiSize
  public let text: String

  public init(
    agentID: String,
    runtime: AgentTuiRuntime,
    status: AgentTuiStatus,
    size: AgentTuiSize,
    text: String
  ) {
    self.agentID = agentID
    self.runtime = runtime
    self.status = status
    self.size = size
    self.text = text
  }
}

@MainActor
public enum AgentTuiPreviewSupport {
  public enum BridgeState {
    case ready
    case unavailable
    case excluded
  }

  public static let runningSingle = [
    snapshot(
      tuiID: "preview-agent-tui-1",
      spec: AgentTuiSnapshotSpec(
        agentID: PreviewFixtures.agents[0].agentId,
        runtime: .claude,
        status: .running,
        size: AgentTuiSize(rows: 30, cols: 110),
        text: "claude> Investigating the task lane regression"
      )
    )
  ]

  public static let stoppedSingle = [
    snapshot(
      tuiID: "preview-agent-tui-2",
      spec: AgentTuiSnapshotSpec(
        agentID: PreviewFixtures.agents[1].agentId,
        runtime: .codex,
        status: .stopped,
        size: AgentTuiSize(rows: 28, cols: 108),
        text: "codex> Applied the patch and exited cleanly"
      )
    )
  ]

  public static let overflowMixed = [
    snapshot(
      tuiID: "preview-agent-tui-1",
      spec: AgentTuiSnapshotSpec(
        agentID: PreviewFixtures.agents[0].agentId,
        runtime: .claude,
        status: .running,
        size: AgentTuiSize(rows: 30, cols: 110),
        text: "claude> triaging observer findings"
      )
    ),
    snapshot(
      tuiID: "preview-agent-tui-2",
      spec: AgentTuiSnapshotSpec(
        agentID: PreviewFixtures.agents[1].agentId,
        runtime: .codex,
        status: .running,
        size: AgentTuiSize(rows: 32, cols: 120),
        text: "codex> preparing patch set"
      )
    ),
    snapshot(
      tuiID: "preview-agent-tui-3",
      spec: AgentTuiSnapshotSpec(
        agentID: "preview-agent-gemini",
        runtime: .gemini,
        status: .stopped,
        size: AgentTuiSize(rows: 26, cols: 96),
        text: "gemini> report delivered"
      )
    ),
    snapshot(
      tuiID: "preview-agent-tui-4",
      spec: AgentTuiSnapshotSpec(
        agentID: "preview-agent-copilot",
        runtime: .copilot,
        status: .running,
        size: AgentTuiSize(rows: 28, cols: 100),
        text: "copilot> verifying UI snapshots"
      )
    ),
    snapshot(
      tuiID: "preview-agent-tui-5",
      spec: AgentTuiSnapshotSpec(
        agentID: "preview-agent-codex-2",
        runtime: .codex,
        status: .running,
        size: AgentTuiSize(rows: 32, cols: 120),
        text: "codex> replaying terminal script"
      )
    ),
    snapshot(
      tuiID: "preview-agent-tui-6",
      spec: AgentTuiSnapshotSpec(
        agentID: "preview-agent-gemini-2",
        runtime: .gemini,
        status: .stopped,
        size: AgentTuiSize(rows: 24, cols: 88),
        text: "gemini> final notes captured"
      )
    ),
  ]

  public static func snapshot(
    tuiID: String,
    spec: AgentTuiSnapshotSpec
  ) -> AgentTuiSnapshot {
    let lines = spec.text.split(separator: "\n", omittingEmptySubsequences: false)
    let cursorRow = max(lines.count, 1)
    let cursorCol = min((lines.last?.count ?? 0) + 1, spec.size.cols)
    return AgentTuiSnapshot(
      tuiId: tuiID,
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: spec.agentID,
      runtime: spec.runtime.rawValue,
      status: spec.status,
      argv: [spec.runtime.rawValue],
      projectDir: PreviewFixtures.summary.projectDir ?? "/Users/example/Projects/harness",
      size: spec.size,
      screen: AgentTuiScreenSnapshot(
        rows: spec.size.rows,
        cols: spec.size.cols,
        cursorRow: cursorRow,
        cursorCol: cursorCol,
        text: spec.text
      ),
      transcriptPath: "/Users/example/Projects/harness/transcripts/\(tuiID).log",
      exitCode: spec.status.isActive ? nil : 0,
      signal: nil,
      error: spec.status == .failed ? "Preview failure" : nil,
      createdAt: "2026-04-11T09:00:00Z",
      updatedAt: "2026-04-11T09:01:00Z"
    )
  }

  public static func makeStore(
    tuis: [AgentTuiSnapshot],
    selectedTuiID: String? = nil,
    bridgeState: BridgeState = .ready
  ) -> HarnessMonitorStore {
    let baseFixtures = PreviewHarnessClient.Fixtures.populated
    let fixtures = PreviewHarnessClient.Fixtures(
      health: baseFixtures.health,
      projects: baseFixtures.projects,
      sessions: baseFixtures.sessions,
      detail: baseFixtures.detail,
      timeline: baseFixtures.timeline,
      readySessionID: baseFixtures.readySessionID,
      detailsBySessionID: baseFixtures.detailsBySessionID,
      coreDetailsBySessionID: baseFixtures.coreDetailsBySessionID,
      timelinesBySessionID: baseFixtures.timelinesBySessionID,
      agentTuisBySessionID: [PreviewFixtures.summary.sessionId: tuis]
    )

    let hostBridgeOverride = makeHostBridgeOverride(
      bridgeState: bridgeState,
      activeSessionCount: tuis.filter(\.status.isActive).count
    )
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(
        fixtures: fixtures,
        hostBridgeOverride: hostBridgeOverride
      ),
      voiceCapture: PreviewVoiceCaptureService(),
      modelContainer: HarnessMonitorPreviewStoreFactory.previewContainer
    )

    store.connectionState = .online
    store.health = fixtures.health
    store.daemonStatus = makeStatusReport(
      fixtures: fixtures,
      hostBridgeOverride: hostBridgeOverride
    )
    store.connectionMetrics = ConnectionMetrics(
      transportKind: .webSocket,
      latencyMs: 24,
      averageLatencyMs: 28,
      messagesReceived: 64,
      messagesSent: 64,
      messagesPerSecond: 7.2,
      connectedSince: .now.addingTimeInterval(-900),
      lastMessageAt: .now,
      reconnectAttempt: 0,
      reconnectCount: 0,
      isFallback: false,
      fallbackReason: nil
    )
    store.connectionEvents = [
      ConnectionEvent(
        kind: .connected,
        detail: "Connected via WebSocket",
        transportKind: .webSocket
      )
    ]
    store.sessionIndex.replaceSnapshot(
      projects: fixtures.projects,
      sessions: fixtures.sessions
    )
    store.selectedSessionID = PreviewFixtures.summary.sessionId
    store.selectedSession = PreviewFixtures.detail
    store.timeline = PreviewFixtures.timeline
    let roleByAgent = Dictionary(
      uniqueKeysWithValues: PreviewFixtures.detail.agents.map { ($0.agentId, $0.role) }
    )
    let sortedTuis = AgentTuiListResponse(tuis: tuis)
      .canonicallySorted(roleByAgent: roleByAgent)
      .tuis
    store.selectedAgentTuis = sortedTuis
    if let selectedTuiID {
      store.selectAgentTui(tuiID: selectedTuiID)
    } else {
      store.selectAgentTui(tuiID: sortedTuis.first?.tuiId)
    }
    store.synchronizeActionActor()
    return store
  }
}

extension AgentTuiPreviewSupport {
  private static func makeHostBridgeOverride(
    bridgeState: BridgeState,
    activeSessionCount: Int
  ) -> PreviewHostBridgeOverride {
    let bridgeStatus =
      switch bridgeState {
      case .ready:
        BridgeStatusReport(
          running: true,
          socketPath: "/tmp/harness-preview-bridge.sock",
          pid: 4242,
          startedAt: "2026-04-11T10:00:00Z",
          uptimeSeconds: 600,
          capabilities: [
            "agent-tui": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "unix",
              endpoint: "/tmp/harness-preview-bridge.sock",
              metadata: ["active_sessions": "\(activeSessionCount)"]
            )
          ]
        )
      case .unavailable:
        BridgeStatusReport(
          running: false,
          socketPath: nil,
          pid: nil,
          startedAt: nil,
          uptimeSeconds: nil,
          capabilities: [:]
        )
      case .excluded:
        BridgeStatusReport(
          running: true,
          socketPath: "/tmp/harness-preview-bridge.sock",
          pid: 4242,
          startedAt: "2026-04-11T10:00:00Z",
          uptimeSeconds: 600,
          capabilities: [:]
        )
      }

    return PreviewHostBridgeOverride(
      bridgeStatus: bridgeStatus,
      reconfigureBehavior: bridgeState == .excluded ? .apply : .unsupported
    )
  }

  private static func makeStatusReport(
    fixtures: PreviewHarnessClient.Fixtures,
    hostBridgeOverride: PreviewHostBridgeOverride
  ) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: fixtures.health.version,
        pid: fixtures.health.pid,
        endpoint: fixtures.health.endpoint,
        startedAt: fixtures.health.startedAt,
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        sandboxed: true,
        hostBridge: hostBridgeOverride.hostBridgeManifest
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: "running",
        pid: fixtures.health.pid,
        lastExitStatus: 0
      ),
      projectCount: fixtures.projects.count,
      sessionCount: fixtures.sessions.count,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        databasePath: "/Users/example/Library/Application Support/harness/daemon/harness.db",
        databaseSizeBytes: 1_740_800,
        lastEvent: DaemonAuditEvent(
          recordedAt: "2026-03-28T14:18:00Z",
          level: "info",
          message: "indexed session \(PreviewFixtures.summary.sessionId)"
        )
      )
    )
  }
}
