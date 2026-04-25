import Foundation
import XCTest

@testable import HarnessMonitorE2ECore

final class SwarmStepTimeoutsTests: XCTestCase {
  func testKnownActsUseExplicitBudgets() throws {
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act1"), 45)
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act2"), 45)
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act5"), 30)
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act11"), 20)
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act16"), 20)
  }

  func testUnknownActFallsBackToDefaultBudget() throws {
    XCTAssertEqual(SwarmStepTimeouts.timeout(for: "act99"), SwarmStepTimeouts.defaultTimeout)
  }

  func testEncodedEnvironmentRoundTrips() throws {
    let decoded = try XCTUnwrap(
      SwarmStepTimeouts.decodeEnvironment(SwarmStepTimeouts.encodedEnvironmentValue)
    )
    XCTAssertEqual(decoded["act1"], 45)
    XCTAssertEqual(decoded["act5"], 30)
    XCTAssertEqual(decoded["act16"], 20)
    XCTAssertEqual(decoded["default"], SwarmStepTimeouts.defaultTimeout)
  }
}

final class RecordingDurationBudgetTests: XCTestCase {
  func testNoMaximumAlwaysUsesPollInterval() throws {
    let budget = RecordingDurationBudget(maxDuration: nil, pollInterval: 0.2)
    let start = Date(timeIntervalSince1970: 0)

    XCTAssertEqual(
      try XCTUnwrap(budget.nextWaitInterval(startedAt: start, now: start)),
      0.2,
      accuracy: 0.0001
    )
    XCTAssertEqual(
      try XCTUnwrap(
        budget.nextWaitInterval(startedAt: start, now: start.addingTimeInterval(60))
      ),
      0.2,
      accuracy: 0.0001
    )
  }

  func testMaximumDurationShrinksFinalPollAndThenExpires() throws {
    let budget = RecordingDurationBudget(maxDuration: 2, pollInterval: 0.5)
    let start = Date(timeIntervalSince1970: 0)

    XCTAssertEqual(
      try XCTUnwrap(
        budget.nextWaitInterval(startedAt: start, now: start.addingTimeInterval(1.8))
      ),
      0.2,
      accuracy: 0.0001
    )
    XCTAssertNil(
      budget.nextWaitInterval(startedAt: start, now: start.addingTimeInterval(2))
    )
  }
}
