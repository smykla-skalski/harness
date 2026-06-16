import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
extension PolicyExecutorTests {
  func testQueueDecisionAuditOrdering() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .queueDecision(
        .init(
          id: "d1",
          severity: .needsUser,
          ruleID: "stuck-agent",
          sessionID: "s1",
          agentID: "a1",
          taskID: nil,
          summary: "agent stalled",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(events.first?.severity, .needsUser)
    XCTAssertEqual(events.last?.ruleID, "stuck-agent")
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func testQueueDecisionUpdatesExistingDecisionWithoutDuplicateNotification() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    try await store.insert(
      DecisionDraft(
        id: "d1",
        severity: .warn,
        ruleID: "idle-session",
        sessionID: "s1",
        agentID: nil,
        taskID: nil,
        summary: "old summary",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    )
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .queueDecision(
        .init(
          id: "d1",
          severity: .needsUser,
          ruleID: "idle-session",
          sessionID: "s1",
          agentID: "a1",
          taskID: nil,
          summary: "new summary",
          contextJSON: #"{"agentID":"a1"}"#,
          suggestedActionsJSON: "[]"
        )
      )
    )

    guard case .executed = outcome else {
      XCTFail("updated open decision should execute, got \(outcome)")
      return
    }
    let decision = try await store.decision(id: "d1")
    XCTAssertEqual(decision?.summary, "new summary")
    XCTAssertEqual(decision?.agentID, "a1")
    XCTAssertTrue(api.notifyCalls.isEmpty)
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
  }

  func testQueueDecisionStableOpenReplayAfterCooldownSkipsAudit() async throws {
    let api = FakeAPIClient()
    let clock = TestClock()
    let store = try DecisionStore.makeInMemory(now: { clock.now() })
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(
      api: api,
      decisions: store,
      audit: audit,
      clock: clock,
      cooldown: 1
    )
    let action = SupervisorAction.queueDecision(
      .init(
        id: "idle-session:s1",
        severity: .warn,
        ruleID: "idle-session",
        sessionID: "s1",
        agentID: "a1",
        taskID: nil,
        summary: "Session s1 has had no activity for over 600s.",
        contextJSON: #"{"agentID":"a1","sessionID":"s1"}"#,
        suggestedActionsJSON: "[]"
      )
    )

    let first = await exec.execute(action)
    await clock.advance(by: .seconds(2))
    let replay = await exec.execute(action)

    guard case .executed = first else {
      XCTFail("first queueDecision should execute, got \(first)")
      return
    }
    guard case .skippedDuplicate(let key) = replay else {
      XCTFail("stable open replay should skip after cooldown, got \(replay)")
      return
    }
    XCTAssertEqual(key, action.actionKey)
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(api.notifyCalls.map(\.decisionID), ["idle-session:s1"])
  }

  func testQueueDecisionReopensDismissedDecisionAndNotifies() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    try await store.insert(
      DecisionDraft(
        id: "d1",
        severity: .warn,
        ruleID: "idle-session",
        sessionID: "s1",
        agentID: nil,
        taskID: nil,
        summary: "old summary",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    )
    try await store.dismiss(id: "d1")
    let exec = PolicyExecutor(api: api, decisions: store, audit: InMemoryAuditWriter())

    _ = await exec.execute(
      .queueDecision(
        .init(
          id: "d1",
          severity: .warn,
          ruleID: "idle-session",
          sessionID: "s1",
          agentID: nil,
          taskID: nil,
          summary: "still idle",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        )
      )
    )

    let open = try await store.openDecisions()
    XCTAssertEqual(open.map(\.id), ["d1"])
    XCTAssertEqual(api.notifyCalls.map(\.decisionID), ["d1"])
  }

  func testQueueDecisionUpdatesFutureSnoozedDecisionWithoutReopeningOrNotifying() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    try await store.insert(
      DecisionDraft(
        id: "d1",
        severity: .warn,
        ruleID: "idle-session",
        sessionID: "s1",
        agentID: nil,
        taskID: nil,
        summary: "old summary",
        contextJSON: "{}",
        suggestedActionsJSON: "[]"
      )
    )
    try await store.snooze(id: "d1", until: Date().addingTimeInterval(3_600))
    let exec = PolicyExecutor(api: api, decisions: store, audit: InMemoryAuditWriter())

    _ = await exec.execute(
      .queueDecision(
        .init(
          id: "d1",
          severity: .warn,
          ruleID: "idle-session",
          sessionID: "s1",
          agentID: nil,
          taskID: nil,
          summary: "still idle",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        )
      )
    )

    let decision = try await store.decision(id: "d1")
    XCTAssertEqual(decision?.statusRaw, "snoozed")
    XCTAssertEqual(decision?.summary, "still idle")
    let open = try await store.openDecisions()
    XCTAssertTrue(open.isEmpty)
    XCTAssertTrue(api.notifyCalls.isEmpty)
  }
}
