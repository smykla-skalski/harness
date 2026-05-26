import CloudKit
import Foundation
import HarnessMonitorCloudMirror
import XCTest

final class MobileCloudMirrorAccountStatusTests: XCTestCase {
  func testNotAuthenticatedIsUnavailable() {
    let availability = mobileCloudMirrorAccountAvailability(for: CKError(.notAuthenticated))

    XCTAssertEqual(availability, .unavailable)
  }

  func testAccountTemporarilyUnavailableIsUnavailable() {
    let availability = mobileCloudMirrorAccountAvailability(
      for: CKError(.accountTemporarilyUnavailable)
    )

    XCTAssertEqual(availability, .unavailable)
  }

  func testNetworkErrorIsAvailable() {
    let availability = mobileCloudMirrorAccountAvailability(for: CKError(.networkUnavailable))

    XCTAssertEqual(availability, .available, "a network blip is not an account problem")
  }

  func testZoneNotFoundIsAvailable() {
    let availability = mobileCloudMirrorAccountAvailability(for: CKError(.zoneNotFound))

    XCTAssertEqual(availability, .available)
  }

  func testNonCloudKitErrorIsAvailable() {
    let availability = mobileCloudMirrorAccountAvailability(
      for: NSError(domain: "SomethingElse", code: 42)
    )

    XCTAssertEqual(availability, .available)
  }

  func testNestedNotAuthenticatedIsUnavailable() {
    let wrapped = NSError(
      domain: "MobileMirrorRefresh",
      code: 7,
      userInfo: [NSUnderlyingErrorKey: CKError(.notAuthenticated) as NSError]
    )

    let availability = mobileCloudMirrorAccountAvailability(for: wrapped)

    XCTAssertEqual(availability, .unavailable, "account errors surface even when wrapped")
  }
}
