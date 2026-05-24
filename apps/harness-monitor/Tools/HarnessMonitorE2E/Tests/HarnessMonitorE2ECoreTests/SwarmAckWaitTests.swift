import XCTest

@testable import HarnessMonitorE2ECore

final class SwarmAckWaitTests: XCTestCase {
  func testWaitForAckReturnsWhenAckAppears() throws {
    var attempts = 0
    var currentTime = Date(timeIntervalSince1970: 0)

    let outcome = try SwarmAckWait.waitForAck(
      ackExists: {
        attempts += 1
        return attempts == 3
      },
      stopRequested: { false },
      timeout: 1,
      pollInterval: 0.1,
      now: { currentTime },
      sleep: { interval in
        currentTime = currentTime.addingTimeInterval(interval)
      }
    )

    XCTAssertEqual(outcome, .acknowledged)
    XCTAssertEqual(attempts, 3)
  }

  func testWaitForAckStopsImmediatelyWhenTeardownMarkerAppears() throws {
    let outcome = try SwarmAckWait.waitForAck(
      ackExists: { false },
      stopRequested: { true },
      timeout: 5
    )

    XCTAssertEqual(outcome, .stopped)
  }

  func testWaitForAckTimesOutWhenNeitherAckNorStopAppears() {
    var currentTime = Date(timeIntervalSince1970: 0)

    XCTAssertThrowsError(
      try SwarmAckWait.waitForAck(
        ackExists: { false },
        stopRequested: { false },
        timeout: 0.3,
        pollInterval: 0.1,
        now: { currentTime },
        sleep: { interval in
          currentTime = currentTime.addingTimeInterval(interval)
        }
      )
    ) { error in
      XCTAssertEqual(error as? SwarmAckWait.Failure, .timedOut)
    }
  }
}
