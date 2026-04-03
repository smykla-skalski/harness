import Foundation
import SwiftData

@MainActor
public enum HarnessPreviewStoreFactory {
  public enum Scenario: Sendable {
    case dashboardLoaded
    case cockpitLoaded
    case offlineCached
    case sidebarOverflow
    case empty
  }

  public static func makeStore(
    for scenario: Scenario,
    modelContext: ModelContext? = nil,
    persistenceError: String? = nil
  ) -> HarnessStore {
    let configuration = configuration(for: scenario)
    let store = HarnessStore(
      daemonController: PreviewDaemonController(mode: configuration.mode),
      modelContext: modelContext,
      persistenceError: persistenceError
    )
    store.connectionState = configuration.connectionState
    store.health = configuration.fixtures.health
    store.daemonStatus = configuration.statusReport
    store.connectionMetrics = configuration.connectionMetrics
    store.connectionEvents = configuration.connectionEvents
    store.sessionIndex.replaceSnapshot(
      projects: configuration.fixtures.projects,
      sessions: configuration.fixtures.sessions
    )
    store.bookmarkedSessionIds = configuration.bookmarkedSessionIDs
    store.sessionFilter = configuration.sessionFilter
    store.selectedSessionID = configuration.selectedSessionID
    store.selectedSession = configuration.selectedDetail
    store.timeline = configuration.timeline
    store.isSelectionLoading = false
    store.isShowingCachedData = configuration.isShowingCachedData
    store.persistedSessionCount = configuration.persistedSessionCount
    store.lastPersistedSnapshotAt = configuration.lastPersistedSnapshotAt
    store.synchronizeActionActor()
    return store
  }
}

private struct PreviewStoreConfiguration {
  let mode: PreviewDaemonController.Mode
  let fixtures: PreviewHarnessClient.Fixtures
  let connectionState: HarnessStore.ConnectionState
  let statusReport: DaemonStatusReport
  let connectionMetrics: ConnectionMetrics
  let connectionEvents: [ConnectionEvent]
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessStore.SessionFilter
  let selectedSessionID: String?
  let selectedDetail: SessionDetail?
  let timeline: [TimelineEntry]
  let isShowingCachedData: Bool
  let persistedSessionCount: Int
  let lastPersistedSnapshotAt: Date?
}

private struct PreviewSelectionState {
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessStore.SessionFilter
  let selectedSessionID: String?
  let selectedDetail: SessionDetail?
  let timeline: [TimelineEntry]
}

private struct PreviewPersistenceState {
  let isShowingCachedData: Bool
  let persistedSessionCount: Int
  let lastPersistedSnapshotAt: Date?

  static let unavailable = Self(
    isShowingCachedData: false,
    persistedSessionCount: 0,
    lastPersistedSnapshotAt: nil
  )
}

private extension HarnessPreviewStoreFactory {
  static func configuration(for scenario: Scenario) -> PreviewStoreConfiguration {
    switch scenario {
    case .dashboardLoaded:
      return dashboardConfiguration()
    case .cockpitLoaded:
      return cockpitConfiguration()
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
    selection: PreviewSelectionState
  ) -> PreviewStoreConfiguration {
    PreviewStoreConfiguration(
      mode: mode,
      fixtures: fixtures,
      connectionState: .online,
      statusReport: makeStatusReport(fixtures: fixtures),
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
    persistence: PreviewPersistenceState
  ) -> PreviewStoreConfiguration {
    PreviewStoreConfiguration(
      mode: mode,
      fixtures: fixtures,
      connectionState: .offline(DaemonControlError.daemonOffline.localizedDescription),
      statusReport: makeStatusReport(fixtures: fixtures),
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

  static func makeStatusReport(fixtures: PreviewHarnessClient.Fixtures) -> DaemonStatusReport {
    let hasSessions = !fixtures.sessions.isEmpty
    return DaemonStatusReport(
      manifest: DaemonManifest(
        version: fixtures.health.version,
        pid: fixtures.health.pid,
        endpoint: fixtures.health.endpoint,
        startedAt: fixtures.health.startedAt,
        tokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token"
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
      projectCount: fixtures.projects.count,
      sessionCount: fixtures.sessions.count,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/Users/example/Library/Application Support/harness/daemon",
        manifestPath: "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        authTokenPath: "/Users/example/Library/Application Support/harness/daemon/auth-token",
        authTokenPresent: true,
        eventsPath: "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        cacheRoot: "/Users/example/Library/Application Support/harness/daemon/cache/projects",
        cacheEntryCount: hasSessions ? max(4, fixtures.sessions.count) : 0,
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

  static func makeConnectionEvents(using metrics: ConnectionMetrics) -> [ConnectionEvent] {
    [
      ConnectionEvent(
        kind: .connected,
        detail: "Connected via \(metrics.transportKind.title)",
        transportKind: metrics.transportKind
      )
    ]
  }
}
