import Foundation
@testable import HarnessMonitorIntents
import XCTest

@MainActor
final class NeedsMeCountCloudKitPumpTests: XCTestCase {
  func testTickResolvesCountAndForwardsToSubmit() async {
    let resolver = CountResolver(values: [7])
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(60),
      resolve: { try await resolver.next() },
      submit: { recorder.record($0) }
    )

    await pump.tick()

    XCTAssertEqual(recorder.submitted, [7])
  }

  func testTickSwallowsResolveError() async {
    let recorder = SubmitRecorder()
    let pump = NeedsMeCountCloudKitPump(
      interval: .seconds(60),
      resolve: { throw FakeError.failed },
      submit: { recorder.record($0) }
    )

    await pump.tick()

    XCTAssertEqual(recorder.submitted, [], "Submit must not run when resolve throws")
  }

  func testStartRunsImmediateTickThenLoops() async throws {
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
    let resolver = CountResolver(values: [1, 1, 1, 1, 1, 1])
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
