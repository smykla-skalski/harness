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
    let store = HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
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
    XCTAssertEqual(snapshots[0].connection.kind, "sse")
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
    await clock.advance(by: .seconds(5))
    // Poll until the slow rule is blocked inside gate.wait(), confirming the tick body is
    // in flight. Polling replaces a fixed sleep which is flaky on loaded machines.
    var attempts = 0
    while await gate.waitCount == 0 && attempts < 200 {
      await Task.yield()
      attempts += 1
    }
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

/// Rule that emits a single `logEvent` action every tick. Drives the happy path assertion.
private struct EmitOnceRule: PolicyRule {
  static let ruleID = "test.emit-once"
  let id: String = ruleID
  let name: String = "Emit Once"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    [
      .logEvent(
        .init(
          id: "emit-\(snapshot.id)",
          ruleID: id,
          snapshotID: snapshot.id,
          message: "emit-once"
        ))
    ]
  }
}

/// Rule whose evaluate returns no actions. Used in the quarantine test paired with the
/// `SupervisorService.injectFailure(forRuleID:)` test hook.
private struct NoopRule: PolicyRule {
  let id: String
  let name: String = "Noop"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    []
  }
}

/// Rule that blocks on an external actor gate, simulating a slow evaluate call so
/// `stop()`-while-in-flight tests can assert draining semantics.
private struct SlowRule: PolicyRule {
  static let ruleID = "test.slow"
  let id: String = ruleID
  let name: String = "Slow"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  let gate: RuleGate

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    await gate.wait()
    return []
  }
}

/// Actor-backed latch the slow rule awaits before returning.
private actor RuleGate {
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var released: Bool { isReleased }
  var waitCount: Int { waiters.count }

  func wait() async {
    if isReleased { return }
    await withCheckedContinuation { cont in
      waiters.append(cont)
    }
  }

  func release() {
    isReleased = true
    let pending = waiters
    waiters.removeAll()
    for cont in pending { cont.resume() }
  }
}

/// Observer spy that captures `didEvaluate` / `didExecute` payloads.
private actor SpyObserver: PolicyObserver {
  struct Evaluation: Sendable {
    let ruleID: String
    let actions: [PolicyAction]
  }

  struct Execution: Sendable {
    let action: PolicyAction
    let outcome: PolicyOutcome
  }

  private(set) var snapshots: [SessionsSnapshot] = []
  private(set) var evaluations: [Evaluation] = []
  private(set) var executions: [Execution] = []

  func willTick(_ snapshot: SessionsSnapshot) async {
    snapshots.append(snapshot)
  }
  func didEvaluate(rule: any PolicyRule, actions: [PolicyAction]) async {
    evaluations.append(Evaluation(ruleID: rule.id, actions: actions))
  }
  func didExecute(action: PolicyAction, outcome: PolicyOutcome) async {
    executions.append(Execution(action: action, outcome: outcome))
  }
  func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [PolicyAction.ConfigSuggestion] { [] }
}
