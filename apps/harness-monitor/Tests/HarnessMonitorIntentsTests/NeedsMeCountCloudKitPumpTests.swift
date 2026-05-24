import Foundation
@testable import HarnessMonitorIntents
import XCTest

@MainActor
final class NeedsMeCountCloudKitPumpTests: XCTestCase {
  func testTickResolvesCountForwardsToSubmitAndReportsSuccess() async {
    let resolver = CountResolver(values: [7])
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(60),
      resolve: { try await resolver.next() },
      submit: { recorder.record($0) }
    )

    let ok = await pump.tick()

    XCTAssertTrue(ok)
    XCTAssertEqual(recorder.submitted, [7])
  }

  func testTickSwallowsResolveErrorAndReportsFailure() async {
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(60),
      resolve: { throw FakeError.failed },
      submit: { recorder.record($0) }
    )

    let ok = await pump.tick()

    XCTAssertFalse(ok)
    XCTAssertEqual(recorder.submitted, [], "Submit must not run when resolve throws")
  }

  func testAdvanceReturnsIntervalAfterSuccess() {
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(60),
      resolve: { 0 },
      submit: { _ in }
    )

    XCTAssertEqual(pump.advance(after: true), .seconds(300))
  }

  func testAdvanceReturnsInitialBackoffOnFirstFailure() {
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(60),
      resolve: { 0 },
      submit: { _ in }
    )

    XCTAssertEqual(pump.advance(after: false), .seconds(2))
  }

  func testAdvanceDoublesBackoffPerConsecutiveFailure() {
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(60),
      resolve: { 0 },
      submit: { _ in }
    )

    XCTAssertEqual(pump.advance(after: false), .seconds(2))
    XCTAssertEqual(pump.advance(after: false), .seconds(4))
    XCTAssertEqual(pump.advance(after: false), .seconds(8))
    XCTAssertEqual(pump.advance(after: false), .seconds(16))
  }

  func testAdvanceCapsBackoffAtMax() {
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(10),
      resolve: { 0 },
      submit: { _ in }
    )

    XCTAssertEqual(pump.advance(after: false), .seconds(2))
    XCTAssertEqual(pump.advance(after: false), .seconds(4))
    XCTAssertEqual(pump.advance(after: false), .seconds(8))
    XCTAssertEqual(pump.advance(after: false), .seconds(10), "Backoff capped at maxBackoff")
    XCTAssertEqual(pump.advance(after: false), .seconds(10), "Stays capped on continued failure")
  }

  func testAdvanceResetsBackoffAfterSuccess() {
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .seconds(2),
      maxBackoff: .seconds(60),
      resolve: { 0 },
      submit: { _ in }
    )

    _ = pump.advance(after: false)
    _ = pump.advance(after: false)
    _ = pump.advance(after: true)

    XCTAssertEqual(pump.advance(after: false), .seconds(2), "Failure after success uses initial backoff")
  }

  func testStartRunsImmediateTickThenLoops() async {
    let resolver = CountResolver(values: [3, 4, 5])
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .milliseconds(50),
      resolve: { try await resolver.next() },
      submit: { recorder.record($0) }
    )

    pump.start()
    let final = await waitFor(count: 3, getter: { recorder.submitted.count })
    pump.stop()

    XCTAssertGreaterThanOrEqual(final, 3)
    XCTAssertEqual(Array(recorder.submitted.prefix(3)), [3, 4, 5])
  }

  func testStartIsIdempotent() async {
    let resolver = CountResolver(values: Array(repeating: 1, count: 10))
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .milliseconds(40),
      resolve: { try await resolver.next() },
      submit: { recorder.record($0) }
    )

    pump.start()
    pump.start()
    let final = await waitFor(count: 2, getter: { recorder.submitted.count })
    pump.stop()

    XCTAssertGreaterThanOrEqual(final, 2, "Pump must keep producing ticks after double-start")
    let resolverCalls = await resolver.callCount
    XCTAssertEqual(
      recorder.submitted.count,
      resolverCalls,
      "Double-start must not spin two parallel loops"
    )
  }

  func testStopCancelsLoop() async {
    let resolver = CountResolver(values: Array(repeating: 9, count: 100))
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .milliseconds(40),
      resolve: { try await resolver.next() },
      submit: { recorder.record($0) }
    )

    pump.start()
    _ = await waitFor(count: 1, getter: { recorder.submitted.count })
    pump.stop()
    let countAtStop = recorder.submitted.count
    try? await Task.sleep(nanoseconds: 200_000_000)

    XCTAssertEqual(recorder.submitted.count, countAtStop, "Loop must halt after stop()")
  }

  func testStartRetriesQuicklyAfterEarlyFailure() async {
    let callCounter = ThrowThenSucceedResolver()
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(300),
      initialBackoff: .milliseconds(30),
      maxBackoff: .milliseconds(100),
      resolve: { try await callCounter.next() },
      submit: { recorder.record($0) }
    )

    pump.start()
    let final = await waitFor(count: 1, getter: { recorder.submitted.count }, timeoutMillis: 2_000)
    pump.stop()

    XCTAssertEqual(final, 1, "Pump must reach success via short backoff, not wait 5 minutes")
    XCTAssertEqual(recorder.submitted, [42])
  }

  private func waitFor(
    count target: Int,
    getter: @MainActor () -> Int,
    timeoutMillis: Int = 1_000
  ) async -> Int {
    let stepNanos: UInt64 = 20_000_000
    let maxSteps = max(1, timeoutMillis / 20)
    var steps = 0
    var current = getter()
    while current < target && steps < maxSteps {
      try? await Task.sleep(nanoseconds: stepNanos)
      current = getter()
      steps += 1
    }
    return current
  }
}

private actor CountResolver {
  private var values: [Int]
  private(set) var callCount = 0

  init(values: [Int]) {
    self.values = values
  }

  func next() throws -> Int {
    callCount += 1
    guard !values.isEmpty else {
      throw FakeError.exhausted
    }
    return values.removeFirst()
  }
}

private actor ThrowThenSucceedResolver {
  private var attempts = 0

  func next() throws -> Int {
    attempts += 1
    if attempts < 3 {
      throw FakeError.failed
    }
    return 42
  }
}

@MainActor
private final class SubmitRecorder {
  private(set) var submitted: [Int] = []
  func record(_ count: Int) {
    submitted.append(count)
  }
}

private enum FakeError: Error {
  case failed
  case exhausted
}
