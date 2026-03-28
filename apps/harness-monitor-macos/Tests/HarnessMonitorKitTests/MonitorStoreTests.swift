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

  func testInstallLaunchAgentRefreshesDaemonDiagnostics() async throws {
    let controller = RecordingDaemonController(launchAgentInstalled: false)
    let store = MonitorStore(daemonController: controller)

    await store.bootstrap()
    XCTAssertFalse(store.daemonStatus?.launchAgent.installed ?? true)

    await store.installLaunchAgent()

    XCTAssertTrue(store.daemonStatus?.launchAgent.installed ?? false)
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
}
