import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PolicyExecutorTests: XCTestCase {
  func test_nudgeRoutesToSendManagedAgentInput() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .nudgeAgent(
        .init(agentID: "a1", prompt: "status?", ruleID: "stuck-agent", snapshotID: "s1")
      )
    )

    XCTAssertEqual(api.nudgeCalls, [.init(agentID: "a1", input: "status?")])
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(events.map(\.ruleID), ["stuck-agent", "stuck-agent"])
    guard case .executed(let key) = outcome else {
      XCTFail("expected executed, got \(outcome)")
      return
    }
    XCTAssertEqual(key, "nudge:stuck-agent:a1:s1")
  }

  func test_auditEventsRecordDispatchBeforeExecute() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    _ = await exec.execute(
      .nudgeAgent(
        .init(agentID: "a2", prompt: "ping", ruleID: "stuck-agent", snapshotID: "s1")
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].kind, "actionDispatched")
    XCTAssertEqual(events[1].kind, "actionExecuted")
    XCTAssertLessThanOrEqual(events[0].createdAt, events[1].createdAt)
  }

  func test_duplicateActionKeyIsSkipped() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let first = await exec.execute(
      .nudgeAgent(
        .init(agentID: "a1", prompt: "x", ruleID: "r1", snapshotID: "s1")
      )
    )
    let second = await exec.execute(
      .nudgeAgent(
        .init(agentID: "a1", prompt: "x", ruleID: "r1", snapshotID: "s1")
      )
    )

    guard case .executed = first else {
      XCTFail("first call should dispatch")
      return
    }
    guard case .skippedDuplicate(let key) = second else {
      XCTFail("second call should dedup, got \(second)")
      return
    }
    XCTAssertEqual(key, "nudge:r1:a1:s1")
    XCTAssertEqual(api.nudgeCalls.count, 1)
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
  }

  func test_failedNudgeEmitsActionFailed() async throws {
    let api = FakeAPIClient()
    api.nudgeFailure = HarnessMonitorAPIError.server(code: 500, message: "boom")
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .nudgeAgent(
        .init(agentID: "a1", prompt: "x", ruleID: "r1", snapshotID: "s1")
      )
    )

    guard case .failed = outcome else {
      XCTFail("expected failed, got \(outcome)")
      return
    }
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionFailed"])
  }

  func test_assignTaskRoutesToAPI() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .assignTask(
        .init(taskID: "t1", agentID: "a1", ruleID: "unassigned", snapshotID: "s1")
      )
    )

    XCTAssertEqual(api.assignCalls, [.init(taskID: "t1", agentID: "a1")])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func test_dropTaskRoutesToAPI() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .dropTask(
        .init(taskID: "t2", reason: "stale", ruleID: "r1", snapshotID: "s1")
      )
    )

    XCTAssertEqual(api.dropCalls, [.init(taskID: "t2", reason: "stale")])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func test_queueDecisionAuditOrdering() async throws {
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

  func test_notifyOnlyIsExecutedAndAudited() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .notifyOnly(
        .init(
          ruleID: "daemon-disconnect",
          snapshotID: "s1",
          severity: .warn,
          summary: "daemon down"
        )
      )
    )

    XCTAssertEqual(api.notifyCalls.map(\.summary), ["daemon down"])
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func test_logEventOnlyRecordsAudit() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .logEvent(
        .init(id: "l1", ruleID: "policy-gap", snapshotID: "s1", message: "unknown code")
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(api.nudgeCalls, [])
    XCTAssertEqual(api.assignCalls, [])
    XCTAssertEqual(api.dropCalls, [])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func test_suggestConfigChangeIsAuditedOnly() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .suggestConfigChange(
        .init(
          id: "sg1",
          ruleID: "policy-gap",
          proposalJSON: "{}",
          rationale: "observed new pattern"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
    XCTAssertEqual(api.nudgeCalls, [])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func test_dedupExpiresAfterCooldown() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(
      api: api,
      decisions: store,
      audit: audit,
      cooldown: 0.05
    )

    _ = await exec.execute(
      .nudgeAgent(.init(agentID: "a1", prompt: "x", ruleID: "r1", snapshotID: "s1"))
    )
    try await Task.sleep(nanoseconds: 80_000_000)
    let second = await exec.execute(
      .nudgeAgent(.init(agentID: "a1", prompt: "x", ruleID: "r1", snapshotID: "s1"))
    )

    guard case .executed = second else {
      XCTFail("expected re-execute after cooldown, got \(second)")
      return
    }
    XCTAssertEqual(api.nudgeCalls.count, 2)
  }

  func test_fixtureFactoryWorks() async throws {
    let exec = try PolicyExecutor.fixture()
    let outcome = await exec.execute(
      .logEvent(
        .init(id: "l1", ruleID: "r1", snapshotID: "s1", message: "m")
      )
    )
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }
}
