import XCTest

@testable import HarnessMonitorKit

final class SupervisorTelemetryTests: XCTestCase {
  func test_spanNamesAreStable() {
    XCTAssertEqual(SupervisorTelemetry.tickSpanName, "supervisor.tick")
    XCTAssertEqual(SupervisorTelemetry.ruleEvalSpanName, "supervisor.rule.evaluate")
    XCTAssertEqual(SupervisorTelemetry.actionDispatchSpanName, "supervisor.action.dispatch")
    XCTAssertEqual(SupervisorTelemetry.actionExecuteSpanName, "supervisor.action.execute")
  }

  func test_instrumentationNameIsStable() {
    XCTAssertEqual(SupervisorTelemetry.instrumentationName, "io.harnessmonitor.supervisor")
  }

  func test_tracerIsAvailable() {
    // Phase 1 smoke: the tracer provider is globally initialised so `tracer()` must never
    // return nil. Phase 2 tick-loop code will call the same accessor per tick.
    _ = SupervisorTelemetry.tracer()
  }
}
