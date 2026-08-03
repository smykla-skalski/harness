import Foundation
import XCTest

@testable import HarnessMonitorKit

final class ReviewFileModelPatchTests: XCTestCase {
  func testFilesPatchRequestCarriesGitHubRestContext() throws {
    let request = ReviewsFilesPatchRequest(
      pullRequestID: "PR_1",
      headRefOidExpected: "head",
      paths: ["src/lib.rs"],
      number: 42,
      repositoryFullName: "owner/repo"
    )
    let data = try JSONEncoder().encode(request)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesPatchRequest.self, from: data)
    XCTAssertEqual(parsed.number, 42)
    XCTAssertEqual(parsed.repositoryFullName, "owner/repo")
  }

  func testFilesViewedRoundTrips() throws {
    let request = ReviewsFilesViewedRequest(
      pullRequestID: "PR_1",
      paths: [
        ReviewFilesViewedTarget(
          path: "src/lib.rs",
          expectedPriorState: .unviewed,
          markViewed: true
        )
      ]
    )
    let data = try JSONEncoder().encode(request)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesViewedRequest.self, from: data)
    XCTAssertEqual(parsed.paths.count, 1)
    XCTAssertEqual(parsed.paths[0].expectedPriorState, .unviewed)
    XCTAssertTrue(parsed.paths[0].markViewed)
  }

  func testFilesBlobResponseRoundTrips() throws {
    let response = ReviewsFilesBlobResponse(
      path: "logo.png",
      oid: "abc",
      mime: .png,
      contentBase64: "iVBORw0KGgoAAAA=",
      byteSize: 12,
      fetchedAt: "2026-05-22T10:00:00Z"
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesBlobResponse.self, from: data)
    XCTAssertEqual(parsed.mime, .png)
    XCTAssertEqual(parsed.byteSize, 12)
    XCTAssertFalse(parsed.isTooLarge)
  }

  func testServedByValueRoundTripsSnakeCase() throws {
    let encoded = try JSONEncoder().encode(ReviewFileServedBy.githubRest)
    XCTAssertEqual(String(bytes: encoded, encoding: .utf8), "\"github_rest\"")
  }
}
