import Foundation
import XCTest

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

final class DashboardReviewsSnoozedPullRequestsTests: XCTestCase {
  func testSnoozeLogic() throws {
    var snoozed = DashboardReviewsSnoozedPullRequests()

    let prID = "PR-123"
    let pastDate = Date().addingTimeInterval(-3600)  // 1 hour ago
    let formatter = ISO8601DateFormatter()
    let prUpdatedAt = formatter.string(from: pastDate)

    // Initially not snoozed
    XCTAssertFalse(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: prUpdatedAt))

    // Snooze for 2 hours
    let snoozeUntil = Date().addingTimeInterval(7200)
    snoozed.snooze(prID, condition: .untilDate(snoozeUntil))

    // Now it should be snoozed
    XCTAssertTrue(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: prUpdatedAt))

    // Test expiration
    let futureDate = Date().addingTimeInterval(10000)
    XCTAssertFalse(snoozed.isSnoozed(prID, currentDate: futureDate, currentUpdatedAt: prUpdatedAt))

    // Test unsnooze
    snoozed.snooze(prID, condition: .untilDate(snoozeUntil))
    XCTAssertTrue(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: prUpdatedAt))
    snoozed.unsnooze(prID)
    XCTAssertFalse(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: prUpdatedAt))

    // Test untilActivity
    snoozed.snooze(prID, condition: .untilActivity(lastSeenUpdatedAt: prUpdatedAt))
    XCTAssertTrue(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: prUpdatedAt))
    let newUpdatedAt = formatter.string(from: Date())
    XCTAssertFalse(snoozed.isSnoozed(prID, currentDate: Date(), currentUpdatedAt: newUpdatedAt))
  }
}
