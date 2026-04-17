import Foundation
import SwiftData

extension HarnessMonitorPreviewStoreFactory {
  static func configuration(for scenario: Scenario) -> PreviewStoreConfiguration {
    switch scenario {
    case .dashboardLanding:
      return dashboardLandingConfiguration()
    case .dashboardLoaded:
      return dashboardConfiguration()
    case .cockpitLoaded:
      return cockpitConfiguration()
    case .emptyCockpit:
      return emptyCockpitConfiguration()
    case .toolbarCountRegression:
      return toolbarCountRegressionConfiguration()
    case .agentTuiOverflow:
      return agentTuiOverflowConfiguration()
    case .taskDropCockpit:
      return taskDropConfiguration()
    case .offlineCached:
      return offlineCachedConfiguration()
    case .sidebarOverflow:
      return overflowConfiguration()
    case .empty:
      return emptyConfiguration()
    }
  }

  static func dashboardConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.populated
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .populated,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .active,
        selectedSessionID: nil,
        selectedDetail: nil,
        timeline: []
      )
    )
  }

  static func dashboardLandingConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.dashboardLanding
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .dashboardLanding,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .active,
        selectedSessionID: nil,
        selectedDetail: nil,
        timeline: []
      )
    )
  }

  static func cockpitConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.populated
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .populated,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .active,
        selectedSessionID: PreviewFixtures.summary.sessionId,
        selectedDetail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline
      )
    )
  }

  static func emptyCockpitConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.emptyCockpit
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .populated,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.emptyCockpitSummary.sessionId],
        sessionFilter: .active,
        selectedSessionID: PreviewFixtures.emptyCockpitSummary.sessionId,
        selectedDetail: PreviewFixtures.emptyCockpitDetail,
        timeline: []
      )
    )
  }

  static func toolbarCountRegressionConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.toolbarCountRegression
    let metrics = makeConnectionMetrics(latencyMs: 18, messagesPerSecond: 5.4)
    return PreviewStoreConfiguration(
      mode: .populated,
      fixtures: fixtures,
      connectionState: .online,
      statusReport: makeStatusReport(
        fixtures: fixtures,
        projectCountOverride: 42,
        worktreeCountOverride: 5,
        sessionCountOverride: 6
      ),
      connectionMetrics: metrics,
      connectionEvents: makeConnectionEvents(using: metrics),
      bookmarkedSessionIDs: [],
      sessionFilter: .all,
      selectedSessionID: nil,
      selectedDetail: nil,
      timeline: [],
      isShowingCachedData: false,
      persistedSessionCount: 0,
      lastPersistedSnapshotAt: nil
    )
  }

  static func agentTuiOverflowConfiguration() -> PreviewStoreConfiguration {
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
      agentTuisBySessionID: [
        PreviewFixtures.summary.sessionId: AgentTuiPreviewSupport.overflowMixed
      ]
    )
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .populated,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .active,
        selectedSessionID: PreviewFixtures.summary.sessionId,
        selectedDetail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline
      )
    )
  }

  static func taskDropConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.taskDrop
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .taskDrop,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.taskDropSummary.sessionId],
        sessionFilter: .active,
        selectedSessionID: PreviewFixtures.taskDropSummary.sessionId,
        selectedDetail: PreviewFixtures.taskDropDetail,
        timeline: PreviewFixtures.timeline
      )
    )
  }

  static func offlineCachedConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.populated
    return offlineConfiguration(
      mode: .empty,
      fixtures: fixtures,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .active,
        selectedSessionID: PreviewFixtures.summary.sessionId,
        selectedDetail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline
      ),
      persistence: PreviewPersistenceState(
        isShowingCachedData: true,
        persistedSessionCount: fixtures.sessions.count,
        lastPersistedSnapshotAt: previewCachedSnapshotDate
      )
    )
  }

  static func overflowConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.overflow
    let metrics = makeConnectionMetrics(latencyMs: 38, messagesPerSecond: 12.4)
    return liveConfiguration(
      mode: .overflow,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [
          PreviewFixtures.summary.sessionId,
          PreviewFixtures.overflowSessions[4].sessionId,
        ],
        sessionFilter: .all,
        selectedSessionID: PreviewFixtures.summary.sessionId,
        selectedDetail: PreviewFixtures.detail,
        timeline: PreviewFixtures.timeline
      )
    )
  }

  static func emptyConfiguration() -> PreviewStoreConfiguration {
    offlineConfiguration(
      mode: .empty,
      fixtures: .empty,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [],
        sessionFilter: .active,
        selectedSessionID: nil,
        selectedDetail: nil,
        timeline: []
      ),
      persistence: .unavailable
    )
  }

  static func liveConfiguration(
    mode: PreviewDaemonController.Mode,
    fixtures: PreviewHarnessClient.Fixtures,
    metrics: ConnectionMetrics,
    selection: PreviewSelectionState,
    hostBridgeOverride: PreviewHostBridgeOverride? = nil
  ) -> PreviewStoreConfiguration {
    PreviewStoreConfiguration(
      mode: mode,
      fixtures: fixtures,
      connectionState: .online,
      statusReport: makeStatusReport(
        fixtures: fixtures,
        hostBridgeOverride: hostBridgeOverride
      ),
      connectionMetrics: metrics,
      connectionEvents: makeConnectionEvents(using: metrics),
      bookmarkedSessionIDs: selection.bookmarkedSessionIDs,
      sessionFilter: selection.sessionFilter,
      selectedSessionID: selection.selectedSessionID,
      selectedDetail: selection.selectedDetail,
      timeline: selection.timeline,
      isShowingCachedData: false,
      persistedSessionCount: 0,
      lastPersistedSnapshotAt: nil
    )
  }

  static func offlineConfiguration(
    mode: PreviewDaemonController.Mode,
    fixtures: PreviewHarnessClient.Fixtures,
    selection: PreviewSelectionState,
    persistence: PreviewPersistenceState,
    hostBridgeOverride: PreviewHostBridgeOverride? = nil
  ) -> PreviewStoreConfiguration {
    PreviewStoreConfiguration(
      mode: mode,
      fixtures: fixtures,
      connectionState: .offline(DaemonControlError.daemonOffline.localizedDescription),
      statusReport: makeStatusReport(
        fixtures: fixtures,
        hostBridgeOverride: hostBridgeOverride
      ),
      connectionMetrics: .initial,
      connectionEvents: [],
      bookmarkedSessionIDs: selection.bookmarkedSessionIDs,
      sessionFilter: selection.sessionFilter,
      selectedSessionID: selection.selectedSessionID,
      selectedDetail: selection.selectedDetail,
      timeline: selection.timeline,
      isShowingCachedData: persistence.isShowingCachedData,
      persistedSessionCount: persistence.persistedSessionCount,
      lastPersistedSnapshotAt: persistence.lastPersistedSnapshotAt
    )
  }

  static var previewCachedSnapshotDate: Date {
    ISO8601DateFormatter().date(from: PreviewFixtures.summary.updatedAt) ?? .distantPast
  }

  static func makeStatusReport(
    fixtures: PreviewHarnessClient.Fixtures,
    projectCountOverride: Int? = nil,
    worktreeCountOverride: Int? = nil,
    sessionCountOverride: Int? = nil,
    hostBridgeOverride: PreviewHostBridgeOverride? = nil
  ) -> DaemonStatusReport {
    let hasSessions = !fixtures.sessions.isEmpty
    let hostBridgeManifest = hostBridgeOverride?.hostBridgeManifest ?? HostBridgeManifest()
    return DaemonStatusReport(
      manifest: DaemonManifest(
        version: fixtures.health.version,
        pid: fixtures.health.pid,
        endpoint: fixtures.health.endpoint,
        startedAt: fixtures.health.startedAt,
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        sandboxed: hostBridgeOverride != nil,
        hostBridge: hostBridgeManifest
      ),
      launchAgent: LaunchAgentStatus(
        installed: hasSessions,
        loaded: hasSessions,
        label: "io.harness.daemon",
        path: "/Users/example/Library/LaunchAgents/io.harness.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harness.daemon",
        state: hasSessions ? "running" : nil,
        pid: hasSessions ? fixtures.health.pid : nil,
        lastExitStatus: hasSessions ? 0 : nil
      ),
      projectCount: projectCountOverride ?? fixtures.projects.count,
      worktreeCount: worktreeCountOverride
        ?? fixtures.projects.reduce(0) { count, project in
          count + project.worktrees.count
        },
      sessionCount: sessionCountOverride ?? fixtures.sessions.count,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        databasePath: "/Users/example/Library/Application Support/harness/daemon/harness.db",
        databaseSizeBytes: hasSessions ? 1_740_800 : 0,
        lastEvent: hasSessions
          ? DaemonAuditEvent(
            recordedAt: "2026-03-28T14:18:00Z",
            level: "info",
            message: "indexed session \(fixtures.sessions[0].sessionId)"
          ) : nil
      )
    )
  }

  static func makeConnectionMetrics(
    latencyMs: Int,
    messagesPerSecond: Double
  ) -> ConnectionMetrics {
    ConnectionMetrics(
      transportKind: .webSocket,
      latencyMs: latencyMs,
      averageLatencyMs: latencyMs + 4,
      messagesReceived: 64,
      messagesSent: 64,
      messagesPerSecond: messagesPerSecond,
      connectedSince: .now.addingTimeInterval(-900),
      lastMessageAt: .now,
      reconnectAttempt: 0,
      reconnectCount: 0,
      isFallback: false,
      fallbackReason: nil
    )
  }

  static func makeConnectionEvents(
    using metrics: ConnectionMetrics
  ) -> [ConnectionEvent] {
    [
      ConnectionEvent(
        kind: .connected,
        detail: "Connected via \(metrics.transportKind.title)",
        transportKind: metrics.transportKind
      )
    ]
  }
}
