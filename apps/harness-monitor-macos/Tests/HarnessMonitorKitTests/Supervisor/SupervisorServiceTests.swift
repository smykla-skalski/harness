import Foundation
import XCTest

@testable import HarnessMonitorKit

/// Unit tests for the Monitor supervisor tick loop per source plan Task 9. The tests exercise
/// three contracts: a single clock tick fans out snapshot → registry → executor, a failing rule
/// is isolated + quarantined after 5 errors in 10 ticks, and `stop()` drains any tick already in
/// flight. All timing is driven by `TestClock` so the suite stays deterministic.
final class SupervisorServiceTests: XCTestCase {
  @MainActor
  func test_singleTickBuildsSnapshotFromStore() async throws {
    let clock = TestClock()
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    let registry = PolicyRegistry()
    await registry.register(NoopRule(id: "test.noop"))
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let executor = try PolicyExecutor.fixture()
    let service = SupervisorService(
      store: store,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 10
    )

    await service.runOneTick()

    let snapshots = await observer.snapshots
    XCTAssertEqual(snapshots.count, 1, "store-backed tick should notify observers once")
    XCTAssertEqual(snapshots[0].sessions.count, 2, "snapshot should include fixture sessions")
    XCTAssertEqual(snapshots[0].connection.kind, "ws")
  }

  func test_singleTickEvaluatesAndDispatches() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let emitter = EmitOnceRule()
    await registry.register(emitter)
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let executor = try PolicyExecutor.fixture()
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 10
    )

    // Drive a single tick directly — no start/stop, no clock dance.
    await service.runOneTick()

    let evaluations = await observer.evaluations
    let executions = await observer.executions
    XCTAssertEqual(evaluations.count, 1, "evaluate should fire once per tick")
    XCTAssertEqual(evaluations.first?.ruleID, EmitOnceRule.ruleID)
    XCTAssertEqual(evaluations.first?.actions.count, 1)
    XCTAssertEqual(executions.count, 1, "executor should receive one action")
    XCTAssertEqual(executions.first?.action.actionKey, evaluations.first?.actions[0].actionKey)
  }

  func test_disabledRuleOverrideSkipsEvaluation() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let recorder = ContextRecorder()
    await registry.register(ContextRecordingRule(id: "test.disabled", recorder: recorder))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "test.disabled",
        enabled: false,
        defaultBehavior: .cautious,
        parameters: [:]
      )
    ])
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: try PolicyExecutor.fixture(),
      clock: clock,
      interval: 10
    )

    await service.runOneTick()

    let contexts = await recorder.snapshot()
    XCTAssertTrue(contexts.isEmpty)
  }

  func test_ruleReceivesRegistryParameterOverrides() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let recorder = ContextRecorder()
    await registry.register(ContextRecordingRule(id: "test.parameters", recorder: recorder))
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "test.parameters",
        enabled: true,
        defaultBehavior: .aggressive,
        parameters: ["threshold": "120"]
      )
    ])
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: try PolicyExecutor.fixture(),
      clock: clock,
      interval: 10
    )

    await service.runOneTick()

    let contexts = await recorder.snapshot()
    XCTAssertEqual(contexts.count, 1)
    XCTAssertEqual(contexts.first?.parameters.int("threshold", default: 0), 120)
  }

  func test_secondTickContextIncludesRecentActionKeysAndLastFiredAt() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let recorder = ContextRecorder()
    let rule = ContextRecordingRule(
      id: "test.context",
      recorder: recorder,
      emittedActionID: "context-action"
    )
    await registry.register(rule)
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: try PolicyExecutor.fixture(),
      clock: clock,
      interval: 10
    )

    await service.runOneTick()
    await service.runOneTick()

    let contexts = await recorder.snapshot()
    XCTAssertEqual(contexts.count, 2)
    XCTAssertNil(contexts[0].lastFiredAt)
    XCTAssertNotNil(contexts[1].lastFiredAt)
    XCTAssertTrue(contexts[1].recentActionKeys.contains("log:test.context:context-action"))
  }

  func test_failingRuleIsIsolatedAndQuarantinedAfterThreshold() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let failing = NoopRule(id: "test.failing")
    let healthy = EmitOnceRule()
    await registry.register(failing)
    await registry.register(healthy)
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let executor = try PolicyExecutor.fixture()
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 1
    )
    // Arm the per-rule failure injection hook for the failing rule. The supervisor reads this
    // set before invoking evaluate and treats the rule as failed — simulating a rule that throws
    // at runtime without changing the frozen `PolicyRule` protocol. Injection persists across
    // ticks until the rule is quarantined.
    await service.injectFailure(forRuleID: "test.failing")

    // Run 6 ticks directly — more than the quarantine threshold of 5 in the 10-tick window.
    for _ in 0..<6 {
      await service.runOneTick()
    }

    let quarantined = await service.quarantinedRuleIDs()
    XCTAssertTrue(
      quarantined.contains("test.failing"),
      "rule should be quarantined after 5 errors in 10 ticks"
    )
    XCTAssertFalse(
      quarantined.contains(EmitOnceRule.ruleID),
      "healthy rule should stay out of quarantine"
    )
    let executions = await observer.executions
    let quarantineDecisions = executions.filter { exec in
      if case .queueDecision(let payload) = exec.action, payload.ruleID == "test.failing" {
        return true
      }
      return false
    }
    XCTAssertGreaterThanOrEqual(
      quarantineDecisions.count,
      1,
      "quarantine must queue a decision for the failing rule"
    )
  }

  func test_quietHoursSuppressAutomaticSideEffectsButKeepDecisions() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    await registry.register(AutoActionRule())
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let executor = try PolicyExecutor.fixture()
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 10
    )
    await service.setQuietHoursWindow(SupervisorQuietHoursWindow(startMinutes: 0, endMinutes: 0))

    await service.runOneTick()

    let evaluations = await observer.evaluations
    XCTAssertEqual(evaluations.count, 1)
    XCTAssertEqual(evaluations.first?.actions.count, 2)

    let executions = await observer.executions
    XCTAssertEqual(executions.count, 1, "quiet hours should suppress the automatic side effect")
    guard case .queueDecision(let payload) = executions.first?.action else {
      return XCTFail("quiet hours should still allow decision queueing")
    }
    XCTAssertEqual(payload.id, "decision-auto-action")
  }

  func test_stopDrainsInFlightTick() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    let gate = RuleGate()
    let slow = SlowRule(gate: gate)
    await registry.register(slow)
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let executor = try PolicyExecutor.fixture()
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 5
    )

    await service.start()
    let sleepDeadline = Date().addingTimeInterval(2)
    while clock.pendingSleepCount == 0 && Date() < sleepDeadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertEqual(
      clock.pendingSleepCount,
      1,
      "run loop should register its initial sleep before the test advances the manual clock"
    )
    await clock.advance(by: .seconds(5))
    // Poll until the slow rule is blocked inside gate.wait(), confirming the tick body is
    // in flight after the clock resumes the registered sleep. Polling replaces a fixed sleep
    // which is flaky on loaded machines.
    let deadline = Date().addingTimeInterval(2)
    while await gate.waitCount == 0 && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let waitCount = await gate.waitCount
    XCTAssertEqual(waitCount, 1, "slow rule should be waiting before stop")
    let isReleased = await gate.released
    XCTAssertFalse(isReleased, "slow rule should be blocked before stop")

    let stopSignal = Task { await service.stop() }
    // Unblock the gate. Stop must drain the in-flight tick before returning.
    await gate.release()
    _ = await stopSignal.value

    let evaluations = await observer.evaluations
    XCTAssertEqual(evaluations.count, 1, "the in-flight tick must finish before stop returns")
  }
}
