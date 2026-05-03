import XCTest

@testable import HarnessMonitorKit

@MainActor
final class SupervisorNoticeNotificationTests: XCTestCase {
  func test_supervisorNoticeRequestCarriesRuleIDWithoutDecisionID() async throws {
    let request = try await HarnessMonitorNotificationRequestFactory.makeSupervisorNoticeRequest(
      severity: .warn,
      summary: "Daemon disconnected",
      ruleID: "daemon-disconnect"
    )

    XCTAssertEqual(request.content.interruptionLevel, .active)
    XCTAssertEqual(
      request.content.categoryIdentifier,
      HarnessMonitorNotificationCategoryID.statusActions
    )
    XCTAssertEqual(
      request.content.userInfo[HarnessMonitorSupervisorNotificationID.ruleIDKey] as? String,
      "daemon-disconnect"
    )
    XCTAssertNil(request.content.userInfo[HarnessMonitorSupervisorNotificationID.decisionIDKey])
    XCTAssertTrue(
      request.identifier.hasPrefix(HarnessMonitorSupervisorNotificationID.noticeRequestPrefix)
    )
  }
}
