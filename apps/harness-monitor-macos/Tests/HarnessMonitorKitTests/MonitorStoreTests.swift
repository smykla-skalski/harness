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
}
