import Foundation
import XCTest

@testable import HarnessMonitorKit

final class SupervisorServiceSuppressionTests: XCTestCase {
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

  func test_cautiousDefaultBehaviorOverrideSuppressesAutomaticSideEffects() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    await registry.register(AutoActionRule())
    await registry.applyOverrides([
      PolicyConfigOverride(
        ruleID: "test.auto-action",
        enabled: true,
        defaultBehavior: .cautious,
        parameters: [:]
      )
    ])
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

    await service.runOneTick()

    let executions = await observer.executions
    XCTAssertEqual(executions.count, 1, "cautious override should suppress automatic side effects")
    guard case .queueDecision(let payload) = executions.first?.action else {
      return XCTFail("cautious override should still allow decision queueing")
    }
    XCTAssertEqual(payload.id, "decision-auto-action")
  }

  func test_quietHoursSuppressionDoesNotRecordAutomaticActionAsFired() async throws {
    let clock = TestClock()
    let registry = PolicyRegistry()
    await registry.register(AutoOnlyRule())
    let audit = InMemoryAuditWriter()
    let executor = PolicyExecutor(
      api: FakeAPIClient(),
      decisions: try DecisionStore.makeInMemory(),
      audit: audit
    )
    let observer = SpyObserver()
    await registry.registerObserver(observer)
    let service = SupervisorService(
      store: nil,
      registry: registry,
      executor: executor,
      clock: clock,
      interval: 10
    )
    await service.setQuietHoursWindow(SupervisorQuietHoursWindow(startMinutes: 0, endMinutes: 0))

    await service.runOneTick()
    await service.runOneTick()
    let suppressedExecutions = await observer.executions
    XCTAssertTrue(suppressedExecutions.isEmpty)
    let events = await audit.snapshot()
    let suppressedEvents = events.filter { $0.kind == "actionSuppressed" }
    XCTAssertEqual(suppressedEvents.count, 1)

    await service.setQuietHoursWindow(nil)
    await service.runOneTick()

    let executions = await observer.executions
    XCTAssertEqual(executions.count, 1)
    guard case .nudgeAgent = executions.first?.action else {
      return XCTFail("automatic nudge should dispatch immediately after quiet hours end")
    }
  }

  func test_overlappingAutoActionSuppressionsStayActiveUntilAllOperationsFinish() async throws {
    let service = SupervisorService(
      store: nil,
      registry: PolicyRegistry(),
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )
    let firstGate = RuleGate()
    let secondGate = RuleGate()

    let firstSuppression = Task {
      await service.suppressAutoActions {
        await firstGate.wait()
      }
    }
    let firstDeadline = Date().addingTimeInterval(2)
    while await firstGate.waitCount == 0 && Date() < firstDeadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }

    let secondSuppression = Task {
      await service.suppressAutoActions {
        await secondGate.wait()
      }
    }
    let secondDeadline = Date().addingTimeInterval(2)
    while await secondGate.waitCount == 0 && Date() < secondDeadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }

    let isSuppressedWithBothOperationsRunning = await service.isAutoActionSuppressed(at: .fixed)
    XCTAssertTrue(isSuppressedWithBothOperationsRunning)
    await firstGate.release()
    _ = await firstSuppression.value

    let isSuppressedWithSecondOperationRunning = await service.isAutoActionSuppressed(at: .fixed)
    XCTAssertTrue(
      isSuppressedWithSecondOperationRunning,
      "suppression must stay active while the second operation is still running"
    )

    await secondGate.release()
    _ = await secondSuppression.value

    let isSuppressedAfterBothOperationsFinish = await service.isAutoActionSuppressed(at: .fixed)
    XCTAssertFalse(isSuppressedAfterBothOperationsFinish)
  }

  func test_autoActionSuppressionUnwindsWhenOperationThrows() async throws {
    enum SuppressionTestError: Error {
      case boom
    }
    let service = SupervisorService(
      store: nil,
      registry: PolicyRegistry(),
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )

    do {
      let _: Void = try await service.suppressAutoActions {
        throw SuppressionTestError.boom
      }
      XCTFail("throwing operation should propagate the error")
    } catch SuppressionTestError.boom {
      let isSuppressed = await service.isAutoActionSuppressed(at: .fixed)
      XCTAssertFalse(isSuppressed)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }

  func test_autoActionSuppressionUnwindsWhenOperationIsCancelled() async throws {
    let service = SupervisorService(
      store: nil,
      registry: PolicyRegistry(),
      executor: try PolicyExecutor.fixture(),
      clock: TestClock(),
      interval: 10
    )
    let probe = SuppressionOperationProbe()

    let task = Task {
      try await service.suppressAutoActions {
        await probe.markStarted()
        try await Task.sleep(for: .seconds(60))
      }
    }
    let deadline = Date().addingTimeInterval(2)
    while !(await probe.started) && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }

    let isSuppressedWhileRunning = await service.isAutoActionSuppressed(at: .fixed)
    XCTAssertTrue(isSuppressedWhileRunning)

    task.cancel()
    do {
      try await task.value
      XCTFail("cancelled suppression task should throw")
    } catch is CancellationError {
      let isSuppressedAfterCancellation = await service.isAutoActionSuppressed(at: .fixed)
      XCTAssertFalse(isSuppressedAfterCancellation)
    } catch {
      XCTFail("unexpected error: \(error)")
    }
  }
}

private actor SuppressionOperationProbe {
  private(set) var started = false

  func markStarted() {
    started = true
  }
}
