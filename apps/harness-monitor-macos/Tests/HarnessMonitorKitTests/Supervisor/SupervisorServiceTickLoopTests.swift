import Foundation
import XCTest

@testable import HarnessMonitorKit

final class SupervisorServiceTickLoopTests: XCTestCase {
  func test_tickLatencySamplesClampBackwardClockJumps() async throws {
    let service = SupervisorService(
      store: nil,
      registry: PolicyRegistry(),
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )

    await service.recordTickLatency(
      startedAt: .fixed,
      endedAt: Date.fixed.addingTimeInterval(-30)
    )

    let snapshot = await service.liveTickSnapshot()
    XCTAssertEqual(snapshot.tickLatencyP50Ms, 0)
    XCTAssertEqual(snapshot.tickLatencyP95Ms, 0)
  }

  func test_failedAutomaticActionDoesNotConsumeRecentActionCooldown() async throws {
    let registry = PolicyRegistry()
    await registry.register(AutoOnlyRule())
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let api = FakeAPIClient()
    api.nudgeFailure = HarnessMonitorAPIError.server(code: 500, message: "boom")
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: PolicyExecutor(
        api: api,
        decisions: try DecisionStore.makeInMemory(),
        audit: InMemoryAuditWriter()
      ),
      clock: TestClock(),
      interval: 10
    )

    await service.runOneTick()
    api.nudgeFailure = nil
    await service.runOneTick()

    let executions = await observer.executions
    XCTAssertEqual(executions.count, 2)
    guard case .failed = executions[0].outcome else {
      return XCTFail("first action should fail")
    }
    guard case .executed = executions[1].outcome else {
      return XCTFail("second action should retry and execute")
    }
  }

  func test_observerConfigSuggestionsAreDispatched() async throws {
    let registry = PolicyRegistry()
    let observer = SpyObserver()
    await registry.registerObserver(SuggestionObserver())
    await registry.registerObserver(observer)
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )

    await service.runOneTick()

    let executions = await observer.executions
    XCTAssertEqual(executions.count, 1)
    guard case .suggestConfigChange(let payload) = executions.first?.action else {
      return XCTFail("observer suggestion should dispatch as suggestConfigChange")
    }
    XCTAssertEqual(payload.id, "suggestion-1")
  }

  func test_overlappingTicksCoalesceBehindInFlightTick() async throws {
    let registry = PolicyRegistry()
    let gate = RuleGate()
    await registry.register(SlowRule(gate: gate))
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )

    let firstTick = Task { await service.runOneTick() }
    let deadline = Date().addingTimeInterval(2)
    while await gate.waitCount == 0 && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let waitCount = await gate.waitCount
    XCTAssertEqual(waitCount, 1)

    let secondTick = Task { await service.runOneTick() }
    await gate.release()
    _ = await firstTick.value
    _ = await secondTick.value

    let evaluations = await observer.evaluations
    XCTAssertEqual(evaluations.count, 1, "second tick should await the in-flight tick")
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
    let deadline = Date().addingTimeInterval(2)
    while await gate.waitCount == 0 && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    let waitCount = await gate.waitCount
    XCTAssertEqual(waitCount, 1, "slow rule should be waiting before stop")
    let isReleased = await gate.released
    XCTAssertFalse(isReleased, "slow rule should be blocked before stop")

    let stopSignal = Task { await service.stop() }
    await gate.release()
    _ = await stopSignal.value

    let evaluations = await observer.evaluations
    XCTAssertEqual(evaluations.count, 1, "the in-flight tick must finish before stop returns")
  }
}
