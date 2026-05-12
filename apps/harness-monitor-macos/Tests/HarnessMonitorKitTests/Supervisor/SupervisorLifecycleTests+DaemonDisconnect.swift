import XCTest

@testable import HarnessMonitorKit

extension SupervisorLifecycleTests {
  @MainActor
  func testStartSupervisorClearsDaemonDisconnectDecisionsWhenConnected() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let container = try XCTUnwrap(store.modelContext?.container)
    let clock = TestClock()
    let decisionStore = DecisionStore(container: container, now: { clock.now() })
    try await decisionStore.insert(
      .fixture(id: "daemon-disconnect:old", ruleID: DaemonDisconnectRule.ruleID, sessionID: nil)
    )
    await clock.advance(by: .seconds(1))
    try await decisionStore.insert(
      .fixture(
        id: DaemonDisconnectRule.activeDecisionID,
        ruleID: DaemonDisconnectRule.ruleID,
        sessionID: nil
      )
    )

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    try await waitForSupervisorOpenDecisionCount(0, store: store)
    let old = try await decisionStore.decision(id: "daemon-disconnect:old")
    let active = try await decisionStore.decision(id: DaemonDisconnectRule.activeDecisionID)
    XCTAssertEqual(old?.statusRaw, "open")
    XCTAssertEqual(active?.statusRaw, "dismissed")
  }

  @MainActor
  func testStartSupervisorKeepsOnlyActiveDaemonDisconnectDecisionWhenDisconnected() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    store.connectionState = .offline("lost connection")
    let container = try XCTUnwrap(store.modelContext?.container)
    let decisionStore = DecisionStore(container: container)
    try await decisionStore.insert(
      .fixture(id: "daemon-disconnect:old", ruleID: DaemonDisconnectRule.ruleID, sessionID: nil)
    )
    try await decisionStore.insert(
      .fixture(
        id: DaemonDisconnectRule.activeDecisionID,
        ruleID: DaemonDisconnectRule.ruleID,
        sessionID: nil
      )
    )

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(1)
    while !store.supervisorOpenDecisions.contains(where: {
      $0.id == DaemonDisconnectRule.activeDecisionID
    }) {
      if clock.now >= deadline {
        XCTFail("Timed out waiting for active daemon disconnect decision")
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    let old = try await decisionStore.decision(id: "daemon-disconnect:old")
    let active = try await decisionStore.decision(id: DaemonDisconnectRule.activeDecisionID)
    XCTAssertEqual(old?.statusRaw, "open")
    XCTAssertEqual(active?.statusRaw, "open")
    XCTAssertFalse(store.supervisorOpenDecisions.contains { $0.id == "daemon-disconnect:old" })
    XCTAssertTrue(
      store.supervisorOpenDecisions.contains {
        $0.id == DaemonDisconnectRule.activeDecisionID
      }
    )
  }

  @MainActor
  func testReconnectClearsOpenDaemonDisconnectDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    store.connectionState = .offline("lost connection")
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    try await decisionStore.insert(
      .fixture(
        id: DaemonDisconnectRule.activeDecisionID,
        ruleID: DaemonDisconnectRule.ruleID,
        sessionID: nil
      )
    )
    try await waitForSupervisorOpenDecisionCount(1, store: store)

    store.connectionState = .online
    store.markConnectionOnline(recordedAt: Date.fixed)

    try await waitForSupervisorOpenDecisionCount(0, store: store)
    let decision = try await decisionStore.decision(id: DaemonDisconnectRule.activeDecisionID)
    XCTAssertEqual(decision?.statusRaw, "dismissed")
  }
}
