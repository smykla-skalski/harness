import HarnessMonitorCore
import XCTest

final class MobileForegroundRefreshBackoffTests: XCTestCase {
  func testStartsAtBaseInterval() {
    let backoff = MobileForegroundRefreshBackoff(
      baseInterval: .seconds(15),
      maximumInterval: .seconds(120)
    )

    XCTAssertEqual(backoff.currentInterval, .seconds(15))
  }

  func testFailureDoublesIntervalUpToMaximum() {
    var backoff = MobileForegroundRefreshBackoff(
      baseInterval: .seconds(15),
      maximumInterval: .seconds(120)
    )

    backoff.recordFailure()
    XCTAssertEqual(backoff.currentInterval, .seconds(30))
    backoff.recordFailure()
    XCTAssertEqual(backoff.currentInterval, .seconds(60))
    backoff.recordFailure()
    XCTAssertEqual(backoff.currentInterval, .seconds(120))
    backoff.recordFailure()
    XCTAssertEqual(backoff.currentInterval, .seconds(120), "interval is capped at the maximum")
  }

  func testSuccessResetsIntervalToBase() {
    var backoff = MobileForegroundRefreshBackoff(
      baseInterval: .seconds(15),
      maximumInterval: .seconds(120)
    )

    backoff.recordFailure()
    backoff.recordFailure()
    XCTAssertGreaterThan(backoff.currentInterval, .seconds(15))

    backoff.recordSuccess()
    XCTAssertEqual(backoff.currentInterval, .seconds(15))
  }

  func testDefaultsUseFifteenSecondBaseAndTwoMinuteCap() {
    var backoff = MobileForegroundRefreshBackoff()

    XCTAssertEqual(backoff.currentInterval, .seconds(15))
    for _ in 0..<10 {
      backoff.recordFailure()
    }
    XCTAssertEqual(backoff.currentInterval, .seconds(120))
  }

  func testMaximumBelowBaseIsClampedToBase() {
    var backoff = MobileForegroundRefreshBackoff(
      baseInterval: .seconds(20),
      maximumInterval: .seconds(5)
    )

    XCTAssertEqual(backoff.currentInterval, .seconds(20))
    backoff.recordFailure()
    XCTAssertEqual(backoff.currentInterval, .seconds(20), "a maximum below the base never shrinks it")
  }

  func testPairingRefreshThrottleAllowsFirstRequest() {
    var throttle = MobilePairingRefreshThrottle(minimumInterval: 60)

    XCTAssertTrue(throttle.shouldRequest(now: Date(timeIntervalSince1970: 1_000)))
  }

  func testPairingRefreshThrottleBlocksSecondRequestWithinInterval() {
    var throttle = MobilePairingRefreshThrottle(minimumInterval: 60)
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(throttle.shouldRequest(now: start))
    XCTAssertFalse(throttle.shouldRequest(now: start.addingTimeInterval(59)))
  }

  func testPairingRefreshThrottleAllowsAgainAfterInterval() {
    var throttle = MobilePairingRefreshThrottle(minimumInterval: 60)
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(throttle.shouldRequest(now: start))
    XCTAssertFalse(throttle.shouldRequest(now: start.addingTimeInterval(30)))
    XCTAssertTrue(throttle.shouldRequest(now: start.addingTimeInterval(60)))
  }
}
