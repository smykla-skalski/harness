import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class MonitorStoreTests: XCTestCase {
  func testBootstrapLoadsDashboardData() async throws {
    let daemon = MockDaemonController()
    let store = MonitorStore(daemonController: daemon)

    await store.bootstrap()

    XCTAssertEqual(store.connectionState, .online)
    XCTAssertEqual(store.projects, PreviewFixtures.projects)
    XCTAssertEqual(store.sessions.map(\.sessionId), [PreviewFixtures.summary.sessionId])
    XCTAssertEqual(store.health?.status, "ok")
  }

  func testSelectSessionLoadsDetailAndTimeline() async throws {
    let daemon = MockDaemonController()
    let store = MonitorStore(daemonController: daemon)
    await store.bootstrap()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    XCTAssertEqual(store.selectedSession?.session.sessionId, PreviewFixtures.summary.sessionId)
    XCTAssertEqual(store.timeline, PreviewFixtures.timeline)
  }

  func testGroupedSessionsFiltersBySearchTextAndStatus() async throws {
    let daemon = MockDaemonController()
    let store = MonitorStore(daemonController: daemon)
    await store.bootstrap()

    store.searchText = "cockpit"
    store.sessionFilter = .active

    XCTAssertEqual(
      store.groupedSessions.map(\.project.projectId), [PreviewFixtures.summary.projectId])
    XCTAssertEqual(
      store.groupedSessions.first?.sessions.map(\.sessionId), [PreviewFixtures.summary.sessionId])
  }
}

private actor MockDaemonController: DaemonControlling {
  private let client: any MonitorClientProtocol

  init(client: any MonitorClientProtocol = PreviewMonitorClient()) {
    self.client = client
  }

  func bootstrapClient() async throws -> any MonitorClientProtocol {
    client
  }

  func startDaemonClient() async throws -> any MonitorClientProtocol {
    client
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        label: "io.harness.monitor.daemon",
        path: "/tmp/io.harness.monitor.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1
    )
  }

  func installLaunchAgent() async throws -> String {
    "/tmp/io.harness.monitor.daemon.plist"
  }

  func removeLaunchAgent() async throws -> String {
    "removed"
  }
}
