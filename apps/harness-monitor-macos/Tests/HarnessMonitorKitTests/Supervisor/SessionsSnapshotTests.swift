import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SessionsSnapshotTests: XCTestCase {
  func test_snapshotIsStableForIdenticalState() {
    let store = HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let first = SessionsSnapshot.build(from: store, now: .fixed)
    let second = SessionsSnapshot.build(from: store, now: .fixed)
    XCTAssertEqual(first.hash, second.hash)
    XCTAssertFalse(first.hash.isEmpty, "Hash must be non-empty for non-empty state")
    XCTAssertEqual(first.sessions.count, 2)
  }

  func test_idleAgentSurfacesIdleSeconds() throws {
    let store = HarnessMonitorStore.fixture(sessions: .oneIdleAgent(idleSeconds: 600))
    let snapshot = SessionsSnapshot.build(from: store, now: .fixed)
    let agent = try XCTUnwrap(snapshot.sessions.first?.agents.first)
    XCTAssertEqual(agent.idleSeconds, 600)
  }

  func test_hashIgnoresIdAndCreatedAt() {
    let store = HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let first = SessionsSnapshot.build(from: store, now: .fixed)
    let later = SessionsSnapshot.build(
      from: store,
      now: Date.fixed.addingTimeInterval(3600)
    )
    XCTAssertEqual(first.hash, later.hash, "Hash excludes id and createdAt")
    XCTAssertNotEqual(first.id, later.id, "Each build gets a fresh UUID")
  }

  func test_connectionReflectsStoreState() {
    let store = HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let snapshot = SessionsSnapshot.build(from: store, now: .fixed)
    XCTAssertEqual(snapshot.connection.kind, "sse")
  }
}
