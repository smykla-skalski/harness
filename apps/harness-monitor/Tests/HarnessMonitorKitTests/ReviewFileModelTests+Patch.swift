import Foundation
import XCTest

@testable import HarnessMonitorKit

final class ReviewFileModelPatchTests: XCTestCase {
  func testFilesPatchResponseRoundTrips() throws {
    let response = ReviewsFilesPatchResponse(
      pullRequestID: "PR_1",
      patches: [
        ReviewFilePatch(
          path: "src/lib.rs",
          patch: "@@ -1 +1 @@\n-a\n+b",
          status: .modified,
          additions: 1,
          deletions: 1,
          servedBy: .localClone,
          fetchedAt: "2026-05-22T10:00:00Z",
          headRefOid: "abc"
        )
      ],
      drifted: false,
      currentHeadRefOid: "abc",
      fetchedAt: "2026-05-22T10:00:00Z"
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesPatchResponse.self, from: data)
    XCTAssertEqual(parsed.patches[0].servedBy, .localClone)
    XCTAssertFalse(parsed.drifted)
  }

  func testFilesPatchRequestCarriesLocalCloneContext() throws {
    let request = ReviewsFilesPatchRequest(
      pullRequestID: "PR_1",
      headRefOidExpected: "head",
      paths: ["src/lib.rs"],
      number: 42,
      repositoryFullName: "owner/repo",
      baseRefOidExpected: "base",
      headRefName: "renovate/foo",
      baseRefName: "main"
    )
    let data = try JSONEncoder().encode(request)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesPatchRequest.self, from: data)
    XCTAssertEqual(parsed.number, 42)
    XCTAssertEqual(parsed.repositoryFullName, "owner/repo")
    XCTAssertEqual(parsed.baseRefOidExpected, "base")
    XCTAssertEqual(parsed.headRefName, "renovate/foo")
    XCTAssertEqual(parsed.baseRefName, "main")
  }

  func testFilesPreviewResponseRoundTrips() throws {
    let response = ReviewsFilesPreviewResponse(
      pullRequestID: "PR_1",
      previews: [
        ReviewFilePreview(
          path: "src/lib.rs",
          patch: "@@ -1 +1 @@\n-a\n+b",
          status: .modified,
          additions: 1,
          deletions: 1,
          servedBy: .localClone,
          fetchedAt: "2026-05-22T10:00:00Z",
          headRefOid: "abc",
          lineCount: 3,
          lineLimit: 200,
          hasMore: false
        )
      ],
      drifted: false,
      currentHeadRefOid: "abc",
      fetchedAt: "2026-05-22T10:00:00Z"
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesPreviewResponse.self, from: data)
    XCTAssertEqual(parsed.previews[0].servedBy, .localClone)
    XCTAssertEqual(parsed.previews[0].lineLimit, 200)
    XCTAssertFalse(parsed.previews[0].hasMore)
  }

  func testFilePreviewProjectsToPatchForHighlightedRendering() {
    let preview = ReviewFilePreview(
      path: "src/lib.rs",
      patch: "@@ -1 +1 @@\n-a\n+b",
      status: .modified,
      additions: 1,
      deletions: 1,
      truncated: false,
      etag: "etag-1",
      servedBy: .localClone,
      fetchedAt: "2026-05-22T10:00:00Z",
      headRefOid: "abc",
      lineCount: 3,
      lineLimit: 200,
      hasMore: true
    )
    let patch = preview.projectedPatch

    XCTAssertEqual(patch.path, preview.path)
    XCTAssertEqual(patch.patch, preview.patch)
    XCTAssertEqual(patch.etag, preview.etag)
    XCTAssertEqual(patch.headRefOid, preview.headRefOid)
    XCTAssertFalse(patch.truncated)
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

  func testFilesLargeDiffStrategyMatchesDaemonEncoding() throws {
    let json = "\"auto_local_clone\""
    let parsed = try JSONDecoder().decode(
      FilesLargeDiffStrategy.self, from: Data(json.utf8))
    XCTAssertEqual(parsed, .autoLocalClone)
    let encoded = try JSONEncoder().encode(FilesLargeDiffStrategy.forceGitHubRest)
    XCTAssertEqual(String(bytes: encoded, encoding: .utf8), "\"force_git_hub_rest\"")
  }

  func testServedByValueRoundTripsSnakeCase() throws {
    let encoded = try JSONEncoder().encode(ReviewFileServedBy.githubRestFallback)
    XCTAssertEqual(String(bytes: encoded, encoding: .utf8), "\"github_rest_fallback\"")
  }
}
