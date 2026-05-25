import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class OpenReviewsIntentTests: XCTestCase {
  func testOpenPullRequestIntentTargetsDeepLinkRouterPullRequestRoute() {
    let entity = PullRequestEntity(
      id: "octo/Hello-World#42",
      title: "Add docs",
      repository: "octo/Hello-World",
      number: 42,
      authorLogin: "alice",
      state: .open,
      reviewerSummary: "0/0 approvals",
      lastUpdated: nil,
      url: URL(string: "https://github.com/octo/Hello-World/pull/42")
    )

    let route = HarnessMonitorDeepLinkRoute.pullRequest(id: entity.id, file: nil)
    let url = HarnessMonitorDeepLinkRouter.url(for: route)

    XCTAssertEqual(url, URL(string: "harness://reviews/octo/Hello-World/42"))
  }

  func testOpenReviewsNeedsMeIntentTargetsRouteWithNeedsMeQueryParam() {
    let url = HarnessMonitorDeepLinkRouter.url(for: .reviews(needsMeOn: true))

    XCTAssertEqual(url, URL(string: "harness://reviews?needsMe=1"))
  }

  func testOpenPullRequestIntentParameterIsExposed() {
    let entity = PullRequestEntity(
      id: "octo/repo#1",
      title: "Demo",
      repository: "octo/repo",
      number: 1,
      authorLogin: nil,
      state: .open,
      reviewerSummary: "0/0 approvals",
      lastUpdated: nil,
      url: nil
    )

    let intent = OpenPullRequestIntent(target: entity)

    XCTAssertEqual(intent.target.id, "octo/repo#1")
  }

  func testOpenReviewsNeedsMeIntentCanBeInitialised() {
    XCTAssertNoThrow(OpenReviewsNeedsMeIntent())
  }
}
