import XCTest

@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
final class ScreenRecorderStartGateTests: XCTestCase {
  func testAwaitStartThenResolveCallsWaitBeforeResolvingWindow() throws {
    var steps: [String] = []

    let value = try ScreenRecorderStartGate.awaitStartThenResolve(
      waitForStartRequest: {
        steps.append("wait")
        return true
      },
      resolveCapture: {
        steps.append("resolve")
        return "capture-window"
      }
    )

    XCTAssertEqual(value, "capture-window")
    XCTAssertEqual(steps, ["wait", "resolve"])
  }

  func testAwaitStartThenResolveSkipsWindowResolutionWhenCancelled() throws {
    var steps: [String] = []

    let value = try ScreenRecorderStartGate.awaitStartThenResolve(
      waitForStartRequest: {
        steps.append("wait")
        return false
      },
      resolveCapture: {
        steps.append("resolve")
        return "capture-window"
      }
    )

    XCTAssertNil(value)
    XCTAssertEqual(steps, ["wait"])
  }

  func testAwaitStartThenResolvePollsUntilWindowAppears() throws {
    var attempts = 0
    var currentTime = Date(timeIntervalSince1970: 0)

    let value = try ScreenRecorderStartGate.awaitStartThenResolve(
      waitForStartRequest: { true },
      resolveCapture: {
        attempts += 1
        return attempts == 3 ? "capture-window" : nil
      },
      timeout: 1,
      pollInterval: 0.1,
      now: { currentTime },
      sleep: { interval in
        currentTime = currentTime.addingTimeInterval(interval)
      }
    )

    XCTAssertEqual(value, "capture-window")
    XCTAssertEqual(attempts, 3)
  }

  func testAwaitStartThenResolveFailsWhenWindowNeverAppears() {
    var currentTime = Date(timeIntervalSince1970: 0)

    XCTAssertThrowsError(
      try ScreenRecorderStartGate.awaitStartThenResolve(
        waitForStartRequest: { true },
        resolveCapture: { Optional<String>.none },
        timeout: 0.3,
        pollInterval: 0.1,
        now: { currentTime },
        sleep: { interval in
          currentTime = currentTime.addingTimeInterval(interval)
        }
      )
    ) { error in
      XCTAssertEqual(
        error as? ScreenRecorder.Failure,
        .monitorWindowStartTimedOut(0.3)
      )
    }
  }
}
