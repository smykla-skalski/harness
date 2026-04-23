import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SessionsSnapshotTests: XCTestCase {
  func test_snapshotIsStableForIdenticalState() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let first = await SessionsSnapshot.build(from: store, now: .fixed)
    let second = await SessionsSnapshot.build(from: store, now: .fixed)
    XCTAssertEqual(first.hash, second.hash)
    XCTAssertFalse(first.hash.isEmpty, "Hash must be non-empty for non-empty state")
    XCTAssertEqual(first.sessions.count, 2)
  }

  func test_idleAgentSurfacesIdleSeconds() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .oneIdleAgent(idleSeconds: 600))
    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)
    let agent = try XCTUnwrap(snapshot.sessions.first?.agents.first)
    XCTAssertEqual(agent.idleSeconds, 600)
  }

  func test_hashIgnoresIdAndCreatedAt() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let first = await SessionsSnapshot.build(from: store, now: .fixed)
    let later = await SessionsSnapshot.build(
      from: store,
      now: Date.fixed.addingTimeInterval(3600)
    )
    XCTAssertEqual(first.hash, later.hash, "Hash excludes id and createdAt")
    XCTAssertNotEqual(first.id, later.id, "Each build gets a fresh UUID")
  }

  func test_connectionReflectsStoreState() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)
    XCTAssertEqual(snapshot.connection.kind, "ws")
    XCTAssertEqual(snapshot.connection.lastMessageAt, Date.fixed.addingTimeInterval(-4))
    XCTAssertEqual(snapshot.connection.reconnectAttempt, 2)
  }

  func test_nonSelectedSessionHydratesFromCachedDetail() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)
    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "sess-beta" })
    XCTAssertEqual(session.agents.count, 2)
    XCTAssertEqual(session.tasks.count, 1)
    XCTAssertEqual(session.timelineDensityLastMinute, 1)
    let issue = try XCTUnwrap(session.observerIssues.first)
    XCTAssertEqual(issue.code, "POL-001")
    XCTAssertNotEqual(issue.firstSeen, Date(timeIntervalSince1970: 0))
  }

  func test_selectedSessionIncludesPendingCodexApprovals() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)
    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "sess-alpha" })
    XCTAssertEqual(session.pendingCodexApprovals.count, 1)
    XCTAssertEqual(session.pendingCodexApprovals.first?.id, "approval-alpha")
    XCTAssertEqual(session.pendingCodexApprovals.first?.title, "Approve command")
  }
}
