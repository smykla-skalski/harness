import Foundation
import XCTest

@testable import HarnessMonitorIntents

final class IntentDonationRecorderTests: XCTestCase {
  func testRecentIDsReturnsMostRecentFirst() async {
    let recorder = IntentDonationRecorder(capacity: 5)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "c")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["c", "b", "a"])
  }

  func testDuplicateDonationMovesEntryToFront() async {
    let recorder = IntentDonationRecorder(capacity: 5)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "a")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["a", "b"])
  }

  func testCapacityEvictsOldestEntry() async {
    let recorder = IntentDonationRecorder(capacity: 3)
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.recordDonation(pullRequestID: "b")
    await recorder.recordDonation(pullRequestID: "c")
    await recorder.recordDonation(pullRequestID: "d")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["d", "c", "b"])
  }

  func testEmptyOrBlankIDsAreIgnored() async {
    let recorder = IntentDonationRecorder()
    await recorder.recordDonation(pullRequestID: "")
    await recorder.recordDonation(pullRequestID: "   ")
    await recorder.recordDonation(pullRequestID: "a")

    let observed = await recorder.recentIDs()
    XCTAssertEqual(observed, ["a"])
  }

  func testClearWipesRecorder() async {
    let recorder = IntentDonationRecorder()
    await recorder.recordDonation(pullRequestID: "a")
    await recorder.clear()

    let count = await recorder.countForTesting
    XCTAssertEqual(count, 0)
  }
}
