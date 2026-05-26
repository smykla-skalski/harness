import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit
import HarnessMonitorUIPreviewable

final class AppOpenAnythingContextMappingTests: XCTestCase {
  func testReviewsRouteMapsToReviewsDomain() {
    XCTAssertEqual(openAnythingContextDomain(forDashboardRoute: .reviews), .reviews)
  }

  func testTaskBoardRouteMapsToTaskBoardDomain() {
    XCTAssertEqual(openAnythingContextDomain(forDashboardRoute: .taskBoard), .taskBoard)
  }

  func testUnmappedRoutesHaveNoContextDomain() {
    XCTAssertNil(openAnythingContextDomain(forDashboardRoute: .policyCanvas))
    XCTAssertNil(openAnythingContextDomain(forDashboardRoute: .notifications))
    XCTAssertNil(openAnythingContextDomain(forDashboardRoute: .diagnostics))
    XCTAssertNil(openAnythingContextDomain(forDashboardRoute: .debugging))
  }
}
