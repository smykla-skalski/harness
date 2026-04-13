import Foundation

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
      agentID: PreviewFixtures.agents[0].agentId,
      runtime: .claude,
      status: .running,
      rows: 30,
      cols: 110,
      text: "claude> Investigating the task lane regression"
    )
  ]

  public static let stoppedSingle = [
    snapshot(
      tuiID: "preview-agent-tui-2",
      agentID: PreviewFixtures.agents[1].agentId,
      runtime: .codex,
      status: .stopped,
      rows: 28,
      cols: 108,
      text: "codex> Applied the patch and exited cleanly"
    )
  ]

  public static let overflowMixed = [
    snapshot(
      tuiID: "preview-agent-tui-1",
      agentID: PreviewFixtures.agents[0].agentId,
      runtime: .claude,
      status: .running,
      rows: 30,
      cols: 110,
      text: "claude> triaging observer findings"
    ),
    snapshot(
      tuiID: "preview-agent-tui-2",
      agentID: PreviewFixtures.agents[1].agentId,
      runtime: .codex,
      status: .running,
      rows: 32,
      cols: 120,
      text: "codex> preparing patch set"
    ),
    snapshot(
      tuiID: "preview-agent-tui-3",
      agentID: "preview-agent-gemini",
      runtime: .gemini,
      status: .stopped,
      rows: 26,
      cols: 96,
      text: "gemini> report delivered"
    ),
    snapshot(
      tuiID: "preview-agent-tui-4",
      agentID: "preview-agent-copilot",
      runtime: .copilot,
      status: .running,
      rows: 28,
      cols: 100,
      text: "copilot> verifying UI snapshots"
    ),
    snapshot(
      tuiID: "preview-agent-tui-5",
      agentID: "preview-agent-codex-2",
      runtime: .codex,
      status: .running,
      rows: 32,
      cols: 120,
      text: "codex> replaying terminal script"
    ),
    snapshot(
      tuiID: "preview-agent-tui-6",
      agentID: "preview-agent-gemini-2",
      runtime: .gemini,
      status: .stopped,
      rows: 24,
      cols: 88,
      text: "gemini> final notes captured"
    ),
  ]

  public static func snapshot(
    tuiID: String,
    agentID: String,
    runtime: AgentTuiRuntime,
    status: AgentTuiStatus,
    rows: Int,
    cols: Int,
    text: String
  ) -> AgentTuiSnapshot {
    AgentTuiSnapshot(
      tuiId: tuiID,
      sessionId: PreviewFixtures.summary.sessionId,
      agentId: agentID,
      runtime: runtime.rawValue,
      status: status,
      argv: [runtime.rawValue],
      projectDir: PreviewFixtures.summary.projectDir ?? "/Users/example/Projects/harness",
      size: AgentTuiSize(rows: rows, cols: cols),
      screen: AgentTuiScreenSnapshot(
        rows: rows,
        cols: cols,
        cursorRow: max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1),
        cursorCol: min(
          (text.split(separator: "\n", omittingEmptySubsequences: false).last?.count ?? 0) + 1, cols
        ),
        text: text
      ),
      transcriptPath: "/Users/example/Projects/harness/transcripts/\(tuiID).log",
      exitCode: status.isActive ? nil : 0,
      signal: nil,
      error: status == .failed ? "Preview failure" : nil,
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
