import Foundation

extension HarnessMonitorPreviewStoreFactory {
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
