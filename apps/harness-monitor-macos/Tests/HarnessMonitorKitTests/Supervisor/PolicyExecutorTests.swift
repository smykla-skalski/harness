import Foundation
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PolicyExecutorTests: XCTestCase {
  func testNudgeRoutesToSendManagedAgentInput() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "status?",
          ruleID: "stuck-agent",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
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
    XCTAssertEqual(key, "nudge:stuck-agent:a1:hash-1")
  }

  func testAuditEventsRecordDispatchBeforeExecute() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    _ = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a2",
          prompt: "ping",
          ruleID: "stuck-agent",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].kind, "actionDispatched")
    XCTAssertEqual(events[1].kind, "actionExecuted")
    XCTAssertLessThanOrEqual(events[0].createdAt, events[1].createdAt)
  }

  func testAuditEventsUseInjectedClock() async throws {
    let api = FakeAPIClient()
    let clock = TestClock()
    let store = try DecisionStore.makeInMemory(now: { clock.now() })
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit, clock: clock)

    _ = await exec.execute(
      .logEvent(
        .init(
          id: "l-clock",
          ruleID: "r-clock",
          snapshotID: "s-clock",
          message: "clocked"
        )
      )
    )

    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.createdAt), [.fixed, .fixed])
  }

  func testDuplicateActionKeyIsSkipped() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let first = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )
    let second = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
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
    XCTAssertEqual(key, "nudge:r1:a1:hash-1")
    XCTAssertEqual(api.nudgeCalls.count, 1)
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionExecuted"])
  }

  func testDuplicateActionAcrossSnapshotIDsIsSkippedForEquivalentNudge() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let first = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "tick-1",
          snapshotHash: "stable-hash"
        )
      )
    )
    let second = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "tick-2",
          snapshotHash: "stable-hash"
        )
      )
    )

    guard case .executed = first else {
      XCTFail("first call should dispatch")
      return
    }
    guard case .skippedDuplicate(let key) = second else {
      XCTFail("second call should dedup across equivalent snapshots, got \(second)")
      return
    }
    XCTAssertEqual(key, "nudge:r1:a1:stable-hash")
    XCTAssertEqual(api.nudgeCalls.count, 1)
  }

  func testFailedNudgeEmitsActionFailed() async throws {
    let api = FakeAPIClient()
    api.nudgeFailure = HarnessMonitorAPIError.server(code: 500, message: "boom")
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )

    guard case .failed = outcome else {
      XCTFail("expected failed, got \(outcome)")
      return
    }
    let events = await audit.snapshot()
    XCTAssertEqual(events.map(\.kind), ["actionDispatched", "actionFailed"])
  }

  func testFailedActionCanRetryImmediately() async throws {
    let api = FakeAPIClient()
    api.nudgeFailure = HarnessMonitorAPIError.server(code: 500, message: "boom")
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)
    let action = PolicyAction.nudgeAgent(
      .init(
        agentID: "a1",
        prompt: "x",
        ruleID: "r1",
        snapshotID: "s1",
        snapshotHash: "hash-1"
      )
    )

    let failed = await exec.execute(action)
    api.nudgeFailure = nil
    let retried = await exec.execute(action)

    guard case .failed = failed else {
      XCTFail("first call should fail, got \(failed)")
      return
    }
    guard case .executed = retried else {
      XCTFail("retry should execute, got \(retried)")
      return
    }
    XCTAssertEqual(api.nudgeCalls, [.init(agentID: "a1", input: "x")])
    let events = await audit.snapshot()
    XCTAssertEqual(
      events.map(\.kind),
      ["actionDispatched", "actionFailed", "actionDispatched", "actionExecuted"]
    )
  }

  func testAssignTaskRoutesToAPI() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .assignTask(
        .init(
          taskID: "t1",
          agentID: "a1",
          ruleID: "unassigned",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )

    XCTAssertEqual(api.assignCalls, [.init(taskID: "t1", agentID: "a1")])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func testDropTaskRoutesToAPI() async throws {
    let api = FakeAPIClient()
    let store = try DecisionStore.makeInMemory()
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(api: api, decisions: store, audit: audit)

    let outcome = await exec.execute(
      .dropTask(
        .init(
          taskID: "t2",
          reason: "stale",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )

    XCTAssertEqual(api.dropCalls, [.init(taskID: "t2", reason: "stale")])
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }

  func testDedupExpiresAfterCooldown() async throws {
    let api = FakeAPIClient()
    let clock = TestClock()
    let store = try DecisionStore.makeInMemory(now: { clock.now() })
    let audit = InMemoryAuditWriter()
    let exec = PolicyExecutor(
      api: api,
      decisions: store,
      audit: audit,
      clock: clock,
      cooldown: 60
    )

    _ = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )
    await clock.advance(by: .seconds(61))
    let second = await exec.execute(
      .nudgeAgent(
        .init(
          agentID: "a1",
          prompt: "x",
          ruleID: "r1",
          snapshotID: "s1",
          snapshotHash: "hash-1"
        )
      )
    )

    guard case .executed = second else {
      XCTFail("expected re-execute after cooldown, got \(second)")
      return
    }
    XCTAssertEqual(api.nudgeCalls.count, 2)
  }

  func testFixtureFactoryWorks() async throws {
    let exec = try PolicyExecutor.fixture()
    let outcome = await exec.execute(
      .logEvent(
        .init(
          id: "l1",
          ruleID: "r1",
          snapshotID: "s1",
          message: "m"
        )
      )
    )
    guard case .executed = outcome else {
      XCTFail("expected executed")
      return
    }
  }
}
