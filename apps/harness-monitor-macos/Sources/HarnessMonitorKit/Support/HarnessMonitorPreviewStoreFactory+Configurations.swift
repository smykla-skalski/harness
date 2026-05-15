import Foundation
import SwiftData

extension HarnessMonitorPreviewStoreFactory {
  static func configuration(for scenario: Scenario) -> PreviewStoreConfiguration {
    let builders: [Scenario: () -> PreviewStoreConfiguration] = [
      .dashboardLanding: dashboardLandingConfiguration,
      .dashboardLoaded: dashboardConfiguration,
      .cockpitLoaded: cockpitConfiguration,
      .policyCanvas: cockpitConfiguration,
      .emptyCockpit: emptyCockpitConfiguration,
      .toolbarCountRegression: toolbarCountRegressionConfiguration,
      .codexApprovalUnification: codexApprovalUnificationConfiguration,
      .agentTuiSingle: agentTuiSingleConfiguration,
      .agentTuiOverflow: agentTuiOverflowConfiguration,
      .taskDropCockpit: taskDropConfiguration,
      .taskBoardBoardOnly: taskBoardBoardOnlyConfiguration,
      .offlineCached: offlineCachedConfiguration,
      .sidebarOverflow: overflowConfiguration,
      .empty: emptyConfiguration,
    ]
    guard let builder = builders[scenario] else {
      return emptyConfiguration()
    }
    return builder()
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
        sessionFilter: .all,
        selectedSessionID: nil,
        selectedDetail: nil,
        timeline: []
      )
    )
  }

  static func taskBoardBoardOnlyConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.taskBoardBoardOnly
    let metrics = makeConnectionMetrics(latencyMs: 24, messagesPerSecond: 7.2)
    return liveConfiguration(
      mode: .dashboardLanding,
      fixtures: fixtures,
      metrics: metrics,
      selection: PreviewSelectionState(
        bookmarkedSessionIDs: [PreviewFixtures.summary.sessionId],
        sessionFilter: .all,
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

  static func codexApprovalUnificationConfiguration() -> PreviewStoreConfiguration {
    let fixtures = PreviewHarnessClient.Fixtures.codexApprovalUnification
    let metrics = makeConnectionMetrics(latencyMs: 18, messagesPerSecond: 4.2)
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

  static func agentTuiSingleConfiguration() -> PreviewStoreConfiguration {
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
        PreviewFixtures.summary.sessionId: AgentTuiPreviewSupport.runningSingle
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

}
