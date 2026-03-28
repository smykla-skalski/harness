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
  }
}
