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

  func test_connectionSnapshotKeepsDisconnectedSinceWhenNoMessageHasArrived() async throws {
    let store = HarnessMonitorStore.fixture()
    store.connectionState = .offline("daemon down")
    store.connectionMetrics.disconnectedSince = .fixed

    let snapshot = await SessionsSnapshot.build(
      from: store,
      now: Date.fixed.addingTimeInterval(120)
    )

    XCTAssertEqual(snapshot.connection.kind, "disconnected")
    XCTAssertEqual(snapshot.connection.lastMessageAt, nil)
    XCTAssertEqual(snapshot.connection.disconnectedSince, .fixed)
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
    XCTAssertEqual(issue.firstSeen, Date.fixed.addingTimeInterval(-5))
  }

  func test_selectedSessionIncludesPendingCodexApprovals() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)
    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "sess-alpha" })
    XCTAssertEqual(session.pendingCodexApprovals.count, 1)
    XCTAssertEqual(session.pendingCodexApprovals.first?.id, "approval-alpha")
    XCTAssertEqual(session.pendingCodexApprovals.first?.title, "Approve command")
  }

  func test_unhydratedSessionStillAppearsAsSummaryOnlySnapshot() async throws {
    let store = HarnessMonitorStore.fixture()
    let summary = makeSummary(sessionID: "sess-paused", status: .paused)
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [summary])

    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)

    let session = try XCTUnwrap(snapshot.sessions.first)
    XCTAssertEqual(session.id, "sess-paused")
    XCTAssertEqual(session.statusRaw, "paused")
    XCTAssertTrue(session.agents.isEmpty)
    XCTAssertTrue(session.tasks.isEmpty)
  }

  func test_snapshotReadsFromCacheNotInMemorySelectedSession() async throws {
    // Cache and in-memory selectedSession can diverge for up to 250ms while the
    // debounced cache write is in flight. The supervisor snapshot must use the
    // cached state so multi-window scenarios stay consistent: only one session
    // can be the singleton selectedSession at a time, but all open windows must
    // surface to the supervisor with the same authority.
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let staleDetail = SessionDetail(
      session: try XCTUnwrap(store.selectedSession?.session),
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    store.selectedSession = staleDetail

    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)

    let session = try XCTUnwrap(snapshot.sessions.first { $0.id == "sess-alpha" })
    XCTAssertEqual(
      session.agents.count,
      2,
      "Snapshot must source detail from the cache, not from in-memory selectedSession"
    )
    XCTAssertEqual(session.tasks.count, 1)
  }

  func test_openWindowSessionWithoutCacheReturnsSummaryOnly() async throws {
    let store = HarnessMonitorStore.fixture()
    let summary = makeSummary(sessionID: "sess-open-no-cache", status: .active)
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [summary])
    store.registerOpenSessionWindow(
      windowID: ObjectIdentifier(SessionsSnapshotWindowToken()),
      sessionID: summary.sessionId
    )

    let snapshot = await SessionsSnapshot.build(from: store, now: .fixed)

    let session = try XCTUnwrap(snapshot.sessions.first)
    XCTAssertEqual(session.id, "sess-open-no-cache")
    XCTAssertTrue(session.agents.isEmpty)
    XCTAssertTrue(session.tasks.isEmpty)
  }

  private final class SessionsSnapshotWindowToken {}

  private func makeSummary(sessionID: String, status: SessionStatus) -> SessionSummary {
    SessionSummary(
      projectId: "project-fixture",
      projectName: "fixture",
      projectDir: nil,
      contextRoot: "",
      sessionId: sessionID,
      worktreePath: "",
      sharedPath: "",
      originPath: "",
      branchRef: "",
      title: "Summary only",
      context: "fixture",
      status: status,
      createdAt: "2026-05-05T00:00:00Z",
      updatedAt: "2026-05-05T00:00:00Z",
      lastActivityAt: "2026-05-05T00:00:00Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: .init(
        agentCount: 0,
        activeAgentCount: 0,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
  }
}
