import XCTest

@testable import HarnessMonitorKit

@MainActor
final class MonitorStoreTests: XCTestCase {
  func testBootstrapLoadsDashboardData() async throws {
    let store = await makeBootstrappedStore()

    XCTAssertEqual(store.connectionState, .online)
    XCTAssertEqual(store.projects, PreviewFixtures.projects)
    XCTAssertEqual(store.sessions.map(\.sessionId), [PreviewFixtures.summary.sessionId])
    XCTAssertEqual(store.health?.status, "ok")
    XCTAssertEqual(
      store.diagnostics?.recentEvents.first?.message,
      "daemon ready"
    )
  }

  func testSelectSessionLoadsDetailAndTimeline() async throws {
    let store = await makeBootstrappedStore()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    XCTAssertEqual(store.selectedSession?.session.sessionId, PreviewFixtures.summary.sessionId)
    XCTAssertEqual(store.timeline, PreviewFixtures.timeline)
    XCTAssertEqual(store.actionActorID, PreviewFixtures.summary.leaderId)
  }

  func testGroupedSessionsFiltersBySearchTextAndStatus() async throws {
    let store = await makeBootstrappedStore()

    store.searchText = "cockpit"
    store.sessionFilter = .active

    XCTAssertEqual(
      store.groupedSessions.map(\.project.projectId),
      [PreviewFixtures.summary.projectId]
    )
    XCTAssertEqual(
      store.groupedSessions.first?.sessions.map(\.sessionId),
      [PreviewFixtures.summary.sessionId]
    )
  }

  func testSavedSearchAppliesRicherFilterSlice() async throws {
    let store = MonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 3, activeSessionCount: 2)]
    var activeFixture = SessionFixture(
      sessionId: "sess-active",
      context: "Monitor live cockpit",
      status: .active,
      leaderId: "leader-claude",
      observeId: "observe-active",
      openTaskCount: 1,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      activeAgentCount: 2
    )
    activeFixture.lastActivityAt = "2026-03-28T14:18:00Z"

    var blockedFixture = SessionFixture(
      sessionId: "sess-blocked",
      context: "Blocked review lane",
      status: .active,
      leaderId: "leader-claude",
      observeId: "observe-blocked",
      openTaskCount: 2,
      inProgressTaskCount: 1,
      blockedTaskCount: 1,
      activeAgentCount: 3
    )
    blockedFixture.lastActivityAt = "2026-03-28T14:19:00Z"

    var endedFixture = SessionFixture(
      sessionId: "sess-ended",
      context: "Archived cleanup lane",
      status: .ended,
      leaderId: "leader-claude",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    )
    endedFixture.lastActivityAt = "2026-03-28T14:10:00Z"

    store.sessions = [
      makeSession(activeFixture),
      makeSession(blockedFixture),
      makeSession(endedFixture),
    ]

    let preset = store.savedSearches.first { $0.id == "blocked-followups" }
    XCTAssertNotNil(preset)
    guard let preset else {
      return
    }

    store.applySavedSearch(preset)

    XCTAssertEqual(store.selectedSavedSearchID, preset.id)
    XCTAssertEqual(store.sessionFilter, .active)
    XCTAssertEqual(store.sessionFocusFilter, .blocked)
    XCTAssertEqual(store.searchText, "")
    XCTAssertEqual(store.groupedSessions.flatMap(\.sessions).map(\.sessionId), ["sess-blocked"])
  }

  func testSearchMatchesAcrossTokensAndResetFiltersRestoresDefaults() async throws {
    let store = MonitorStore(daemonController: RecordingDaemonController())
    store.projects = [makeProject(totalSessionCount: 2, activeSessionCount: 1)]
    store.sessions = [
      makeSession(
        .init(
          sessionId: "sess-a",
          context: "Harness cockpit workstream",
          status: .active,
          leaderId: "leader-alpha",
          observeId: "observe-a",
          openTaskCount: 1,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        )
      ),
      makeSession(
        .init(
          sessionId: "sess-b",
          context: "Other lane",
          status: .ended,
          leaderId: "leader-beta",
          observeId: nil,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 0
        )
      ),
    ]

    store.searchText = "harness leader-alpha"
    store.sessionFilter = .all

    XCTAssertEqual(store.groupedSessions.flatMap(\.sessions).map(\.sessionId), ["sess-a"])

    store.resetFilters()

    XCTAssertEqual(store.selectedSavedSearchID, nil)
    XCTAssertEqual(store.searchText, "")
    XCTAssertEqual(store.sessionFilter, .active)
    XCTAssertEqual(store.sessionFocusFilter, .all)
    XCTAssertEqual(store.groupedSessions.flatMap(\.sessions).map(\.sessionId), ["sess-a"])
  }

  func testInstallLaunchAgentRefreshesDaemonDiagnostics() async throws {
    let controller = RecordingDaemonController(launchAgentInstalled: false)
    let store = MonitorStore(daemonController: controller)

    await store.bootstrap()
    XCTAssertFalse(store.daemonStatus?.launchAgent.installed ?? true)

    await store.installLaunchAgent()

    XCTAssertTrue(store.daemonStatus?.launchAgent.installed ?? false)
    XCTAssertTrue(store.daemonStatus?.launchAgent.loaded ?? false)
    XCTAssertEqual(store.daemonStatus?.launchAgent.pid, 4_242)
    XCTAssertEqual(store.daemonStatus?.diagnostics.lastEvent?.message, "launch agent installed")
    XCTAssertEqual(store.lastAction, "Install launch agent")
  }

  func testRemoveLaunchAgentRefreshesDaemonDiagnostics() async throws {
    let controller = RecordingDaemonController(launchAgentInstalled: true)
    let store = MonitorStore(daemonController: controller)

    await store.bootstrap()
    XCTAssertTrue(store.daemonStatus?.launchAgent.installed ?? false)

    await store.removeLaunchAgent()

    XCTAssertFalse(store.daemonStatus?.launchAgent.installed ?? true)
    XCTAssertFalse(store.daemonStatus?.launchAgent.loaded ?? true)
    XCTAssertNil(store.daemonStatus?.launchAgent.pid)
    XCTAssertEqual(store.daemonStatus?.diagnostics.lastEvent?.message, "launch agent removed")
    XCTAssertEqual(store.lastAction, "Remove launch agent")
  }

  func testReconnectRefreshesHealthAndStatus() async throws {
    let store = await makeBootstrappedStore()

    store.health = nil
    store.daemonStatus = nil
    store.connectionState = .offline("stale")

    await store.reconnect()

    XCTAssertEqual(store.connectionState, .online)
    XCTAssertEqual(store.health?.status, "ok")
    XCTAssertEqual(store.daemonStatus?.diagnostics.cacheEntryCount, 2)
    XCTAssertEqual(store.diagnostics?.workspace.cacheEntryCount, 2)
  }

  func testRefreshDiagnosticsLoadsLiveDaemonDiagnostics() async throws {
    let store = await makeBootstrappedStore()

    store.diagnostics = nil

    await store.refreshDiagnostics()

    XCTAssertEqual(store.diagnostics?.workspace.cacheEntryCount, 2)
    XCTAssertEqual(store.diagnostics?.recentEvents.count, 1)
  }

  func testBootstrapFailureSetsOfflineStateAndError() async throws {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.harnessBinaryNotFound
    )
    let store = MonitorStore(daemonController: daemon)

    await store.bootstrap()

    XCTAssertEqual(
      store.connectionState, .offline(DaemonControlError.harnessBinaryNotFound.localizedDescription)
    )
    XCTAssertNotNil(store.lastError)
    XCTAssertNil(store.health)
  }

  func testCreateTaskFailureSetsLastError() async throws {
    let client = FailingMonitorClient()
    let daemon = RecordingDaemonController(client: client)
    let store = MonitorStore(daemonController: daemon)
    await store.bootstrap()
    await store.selectSession("sess-1")

    await store.createTask(title: "broken", context: nil, severity: .high)

    XCTAssertNotNil(store.lastError)
    XCTAssertFalse(store.isBusy)
  }

  func testRefreshWithNoClientTriggersBootstrap() async throws {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = MonitorStore(daemonController: daemon)

    await store.refresh()

    XCTAssertNotNil(store.lastError)
  }

  func testInstallLaunchAgentFailureSetsLastError() async throws {
    let daemon = FailingDaemonController(
      actionError: DaemonControlError.commandFailed("install failed")
    )
    let store = MonitorStore(daemonController: daemon)

    await store.installLaunchAgent()

    XCTAssertEqual(
      store.lastError, DaemonControlError.commandFailed("install failed").localizedDescription)
    XCTAssertFalse(store.isBusy)
  }

  func testRemoveLaunchAgentFailureSetsLastError() async throws {
    let daemon = FailingDaemonController(
      actionError: DaemonControlError.commandFailed("remove failed")
    )
    let store = MonitorStore(daemonController: daemon)

    await store.removeLaunchAgent()

    XCTAssertEqual(
      store.lastError, DaemonControlError.commandFailed("remove failed").localizedDescription)
    XCTAssertFalse(store.isBusy)
  }

  func testRequestEndConfirmationUsesResolvedActor() async throws {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestEndSelectedSessionConfirmation()

    XCTAssertEqual(
      store.pendingConfirmation,
      .endSession(
        sessionID: PreviewFixtures.summary.sessionId,
        actorID: PreviewFixtures.agents[0].agentId
      )
    )
  }

  func testConfirmPendingRemoveAgentExecutesMutation() async throws {
    let client = RecordingMonitorClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.requestRemoveAgentConfirmation(agentID: PreviewFixtures.agents[1].agentId)
    await store.confirmPendingAction()

    XCTAssertNil(store.pendingConfirmation)
    XCTAssertEqual(
      client.recordedCalls(),
      [
        .removeAgent(
          sessionID: PreviewFixtures.summary.sessionId,
          agentID: PreviewFixtures.agents[1].agentId,
          actor: PreviewFixtures.agents[0].agentId
        )
      ]
    )
  }
}

private struct SessionFixture {
  var sessionId: String
  var context: String
  var status: SessionStatus
  var projectName: String = "harness"
  var projectId: String = "project-a"
  var leaderId: String?
  var observeId: String?
  var openTaskCount: Int
  var inProgressTaskCount: Int
  var blockedTaskCount: Int
  var activeAgentCount: Int
  var lastActivityAt: String = "2026-03-28T14:18:00Z"
}

private func makeProject(totalSessionCount: Int, activeSessionCount: Int) -> ProjectSummary {
  ProjectSummary(
    projectId: "project-a",
    name: "harness",
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/project-a",
    activeSessionCount: activeSessionCount,
    totalSessionCount: totalSessionCount
  )
}

private func makeSession(_ fixture: SessionFixture) -> SessionSummary {
  SessionSummary(
    projectId: fixture.projectId,
    projectName: fixture.projectName,
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/\(fixture.projectId)",
    sessionId: fixture.sessionId,
    context: fixture.context,
    status: fixture.status,
    createdAt: "2026-03-28T14:00:00Z",
    updatedAt: fixture.lastActivityAt,
    lastActivityAt: fixture.lastActivityAt,
    leaderId: fixture.leaderId,
    observeId: fixture.observeId,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: fixture.activeAgentCount,
      activeAgentCount: fixture.activeAgentCount,
      openTaskCount: fixture.openTaskCount,
      inProgressTaskCount: fixture.inProgressTaskCount,
      blockedTaskCount: fixture.blockedTaskCount,
      completedTaskCount: 0
    )
  )
}
