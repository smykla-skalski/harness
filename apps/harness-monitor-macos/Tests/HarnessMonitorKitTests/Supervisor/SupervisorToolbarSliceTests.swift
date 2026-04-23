import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorToolbarSliceTests: XCTestCase {
  func test_initialState_isZeroAndNilSeverity() {
    let slice = SupervisorToolbarSlice()
    XCTAssertLessThan(slice.count, 1)
    XCTAssertNil(slice.maxSeverity)
  }

  func test_ingest_updatesCountAndMaxSeverity_fromSimulatedEvents() async {
    let slice = SupervisorToolbarSlice()
    let (stream, continuation) = AsyncStream<DecisionStore.DecisionEvent>.makeStream()

    // Scripted counts returned by the loader, one per event.
    let scripts: [[DecisionSeverity: Int]] = [
      [.warn: 1],
      [.warn: 1, .critical: 2],
      [:],
    ]
    let cursor = AsyncCursor(values: scripts)

    let running = slice.ingest(
      events: stream,
      loadCounts: { await cursor.next() ?? [:] }
    )

    // Drive three events, wait for slice to converge after each.
    continuation.yield(DecisionStore.DecisionEvent(kind: .inserted, decisionID: "a"))
    await waitUntil(slice.count == 1 && slice.maxSeverity == .warn)

    continuation.yield(DecisionStore.DecisionEvent(kind: .inserted, decisionID: "b"))
    await waitUntil(slice.count == 3 && slice.maxSeverity == .critical)

    continuation.yield(DecisionStore.DecisionEvent(kind: .resolved, decisionID: "a"))
    await waitUntil(slice.count < 1 && slice.maxSeverity == nil)

    continuation.finish()
    await running.value
  }

  func test_stop_cancelsInFlightIngest() async {
    let slice = SupervisorToolbarSlice()
    let (stream, continuation) = AsyncStream<DecisionStore.DecisionEvent>.makeStream()
    let running = slice.ingest(events: stream, loadCounts: { [:] })
    slice.stop()
    continuation.finish()
    await running.value
    XCTAssertLessThan(slice.count, 1)
  }

  // MARK: - Helpers

  private func waitUntil(
    _ condition: @autoclosure @escaping () -> Bool,
    timeout: TimeInterval = 1.0
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    XCTAssertTrue(condition(), "condition not satisfied within \(timeout)s")
  }
}

/// Thread-safe cursor over scripted severity snapshots, consumed by the loader closure in the
/// `ingest` path. Each `next()` call advances, so the slice sees a fresh snapshot per event.
private actor AsyncCursor<Value> {
  private var values: [Value]

  init(values: [Value]) {
    self.values = values
  }

  func next() -> Value? {
    guard !values.isEmpty else { return nil }
    return values.removeFirst()
  }
}
