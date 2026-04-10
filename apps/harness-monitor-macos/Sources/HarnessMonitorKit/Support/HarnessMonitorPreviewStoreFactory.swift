import Foundation
import SwiftData

@MainActor
public enum HarnessMonitorPreviewStoreFactory {
  public static let previewContainer: ModelContainer = {
    do {
      return try HarnessMonitorModelContainer.preview()
    } catch {
      fatalError("Preview ModelContainer failed: \(error)")
    }
  }()

  public enum Scenario: Sendable {
    case dashboardLanding
    case dashboardLoaded
    case cockpitLoaded
    case taskDropCockpit
    case offlineCached
    case sidebarOverflow
    case empty
  }

  public static func makeStore(
    for scenario: Scenario,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    voiceCapture: any VoiceCaptureProviding = PreviewVoiceCaptureService()
  ) -> HarnessMonitorStore {
    let configuration = configuration(for: scenario)
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: configuration.mode),
      voiceCapture: voiceCapture,
      modelContainer: modelContainer,
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
  let connectionState: HarnessMonitorStore.ConnectionState
  let statusReport: DaemonStatusReport
  let connectionMetrics: ConnectionMetrics
  let connectionEvents: [ConnectionEvent]
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessMonitorStore.SessionFilter
  let selectedSessionID: String?
  let selectedDetail: SessionDetail?
  let timeline: [TimelineEntry]
  let isShowingCachedData: Bool
  let persistedSessionCount: Int
  let lastPersistedSnapshotAt: Date?
}

private struct PreviewSelectionState {
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessMonitorStore.SessionFilter
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

extension HarnessMonitorPreviewStoreFactory {
  fileprivate static func configuration(for scenario: Scenario) -> PreviewStoreConfiguration {
    switch scenario {
    case .dashboardLanding:
      return dashboardLandingConfiguration()
    case .dashboardLoaded:
      return dashboardConfiguration()
    case .cockpitLoaded:
      return cockpitConfiguration()
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

  fileprivate static func dashboardConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func dashboardLandingConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func cockpitConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func taskDropConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func offlineCachedConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func overflowConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func emptyConfiguration() -> PreviewStoreConfiguration {
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

  fileprivate static func liveConfiguration(
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

  fileprivate static func offlineConfiguration(
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

  fileprivate static var previewCachedSnapshotDate: Date {
    ISO8601DateFormatter().date(from: PreviewFixtures.summary.updatedAt) ?? .distantPast
  }

  fileprivate static func makeStatusReport(
    fixtures: PreviewHarnessClient.Fixtures
  ) -> DaemonStatusReport {
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

  fileprivate static func makeConnectionMetrics(
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

  fileprivate static func makeConnectionEvents(
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
