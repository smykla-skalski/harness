import Foundation
import XCTest

@testable import HarnessMonitorKit

final class ReviewFileModelJSONTests: XCTestCase {

  // MARK: - JSON round-trip parity with daemon

  func testFilesListResponseRoundTrips() throws {
    let response = ReviewsFilesListResponse(
      pullRequestID: "PR_kwDOABC",
      number: 42,
      headRefOid: "abc123",
      headRefName: "renovate/foo",
      baseRefOid: "def456",
      baseRefName: "main",
      repositoryFullName: "owner/repo",
      viewerCanMarkViewed: true,
      files: [
        ReviewFile(
          path: "src/lib.rs",
          changeType: .modified,
          additions: 12,
          deletions: 3,
          languageHint: .rust
        ),
        ReviewFile(
          path: "cmd/main.go",
          changeType: .added,
          additions: 24,
          deletions: 0,
          viewerViewedState: .viewed,
          languageHint: .go
        ),
        ReviewFile(
          path: "web/app.js",
          changeType: .modified,
          additions: 18,
          deletions: 6,
          languageHint: .javascript
        ),
        ReviewFile(
          path: "web/app.tsx",
          changeType: .modified,
          additions: 32,
          deletions: 4,
          viewerViewedState: .viewed,
          languageHint: .typescript
        ),
        ReviewFile(
          path: "web/App.vue",
          changeType: .modified,
          additions: 41,
          deletions: 7,
          languageHint: .vue
        ),
        ReviewFile(
          path: "features/search.feature",
          changeType: .added,
          additions: 19,
          deletions: 0,
          viewerViewedState: .viewed,
          languageHint: .feature,
        ),
      ],
      fetchedAt: "2026-05-22T10:00:00Z",
      rateLimitSnapshot: ReviewsRateLimitSnapshot(
        remaining: 4998,
        limit: 5000,
        resetAt: "2026-05-22T11:00:00Z",
        cost: 1
      )
    )
    let data = try JSONEncoder().encode(response)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesListResponse.self, from: data)
    XCTAssertEqual(parsed.pullRequestID, response.pullRequestID)
    XCTAssertEqual(parsed.number, 42)
    XCTAssertEqual(parsed.headRefOid, response.headRefOid)
    XCTAssertEqual(parsed.headRefName, "renovate/foo")
    XCTAssertEqual(parsed.baseRefOid, "def456")
    XCTAssertEqual(parsed.baseRefName, "main")
    XCTAssertEqual(parsed.repositoryFullName, "owner/repo")
    XCTAssertEqual(parsed.files.count, 6)
    XCTAssertEqual(parsed.files[0].languageHint, .rust)
    XCTAssertEqual(parsed.files[1].languageHint, .go)
    XCTAssertEqual(parsed.files[2].languageHint, .javascript)
    XCTAssertEqual(parsed.files[3].languageHint, .typescript)
    XCTAssertEqual(parsed.files[4].languageHint, .vue)
    XCTAssertEqual(parsed.files[5].languageHint, .feature)
    XCTAssertEqual(parsed.rateLimitSnapshot?.remaining, 4998)
    // New responses default to paginationComplete = true.
    XCTAssertTrue(parsed.paginationComplete)
  }

  func testReviewFileLanguageGoRoundTrips() throws {
    let data = try JSONEncoder().encode(HarnessReviewFileLanguage.go)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), #""go""#)
    let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
    XCTAssertEqual(parsed, .go)
  }

  func testReviewFileLanguageJavaScriptRoundTrips() throws {
    let data = try JSONEncoder().encode(HarnessReviewFileLanguage.javascript)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), #""javascript""#)
    let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
    XCTAssertEqual(parsed, .javascript)
  }

  func testReviewFileLanguageTypeScriptRoundTrips() throws {
    let data = try JSONEncoder().encode(HarnessReviewFileLanguage.typescript)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), #""typescript""#)
    let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
    XCTAssertEqual(parsed, .typescript)
  }

  func testReviewFileLanguageVueRoundTrips() throws {
    let data = try JSONEncoder().encode(HarnessReviewFileLanguage.vue)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), #""vue""#)
    let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
    XCTAssertEqual(parsed, .vue)
  }

  func testReviewFileLanguageFeatureRoundTrips() throws {
    let data = try JSONEncoder().encode(HarnessReviewFileLanguage.feature)
    XCTAssertEqual(String(bytes: data, encoding: .utf8), #""feature""#)
    let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
    XCTAssertEqual(parsed, .feature)
  }

  func testReviewFileLanguageAdditionalFamiliesRoundTrip() throws {
    let cases: [(HarnessReviewFileLanguage, String)] = [
      (.codeowners, #""codeowners""#),
      (.config, #""config""#),
      (.dockerfile, #""dockerfile""#),
      (.gitignore, #""gitignore""#),
      (.goModule, #""go_module""#),
      (.html, #""html""#),
      (.lua, #""lua""#),
      (.makefile, #""makefile""#),
      (.powershell, #""powershell""#),
      (.proto, #""proto""#),
      (.python, #""python""#),
      (.rego, #""rego""#),
      (.ruby, #""ruby""#),
      (.sql, #""sql""#),
      (.stylesheet, #""stylesheet""#),
      (.template, #""template""#),
      (.terraform, #""terraform""#),
      (.toml, #""toml""#),
      (.xml, #""xml""#),
    ]
    for (language, expectedJSON) in cases {
      let data = try JSONEncoder().encode(language)
      XCTAssertEqual(String(bytes: data, encoding: .utf8), expectedJSON)
      let parsed = try JSONDecoder().decode(HarnessReviewFileLanguage.self, from: data)
      XCTAssertEqual(parsed, language)
    }
  }

  func testFilesListResponsePaginationCompleteDefaultsTrueWhenAbsent() throws {
    // Older daemon responses omit the field; the Monitor should treat
    // them as complete so it doesn't surface a spurious warning.
    let json = """
      {
        "pullRequestId": "PR_1",
        "headRefOid": "abc",
        "viewerCanMarkViewed": true,
        "files": [],
        "fetchedAt": "2026-05-22T10:00:00Z"
      }
      """
    let data = Data(json.utf8)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesListResponse.self, from: data)
    XCTAssertTrue(parsed.paginationComplete)
  }

  func testFilesListResponsePaginationPartialSurfaced() throws {
    let json = """
      {
        "pullRequestId": "PR_1",
        "headRefOid": "abc",
        "viewerCanMarkViewed": true,
        "files": [],
        "fetchedAt": "2026-05-22T10:00:00Z",
        "paginationComplete": false
      }
      """
    let data = Data(json.utf8)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesListResponse.self, from: data)
    XCTAssertFalse(parsed.paginationComplete)
  }

  func testFilesListResponseDecodesSnakeCaseFromDaemon() throws {
    // Daemon emits snake_case keys; the Swift types use camelCase. JSON
    // round-trip should accept the daemon's wire format directly because
    // the CodingKeys mirror the Rust serde names.
    let json = """
      {
        "pullRequestId": "PR_1",
        "headRefOid": "abc",
        "viewerCanMarkViewed": true,
        "files": [
          {
            "path": "src/lib.rs",
            "previousPath": null,
            "changeType": "modified",
            "additions": 1,
            "deletions": 1,
            "viewerViewedState": "unviewed",
            "isBinary": false,
            "languageHint": "rust",
            "modeChange": null
          }
        ],
        "fetchedAt": "2026-05-22T10:00:00Z"
      }
      """
    let data = Data(json.utf8)
    let parsed = try JSONDecoder().decode(
      ReviewsFilesListResponse.self, from: data)
    XCTAssertEqual(parsed.files.count, 1)
    XCTAssertEqual(parsed.files[0].changeType, .modified)
    XCTAssertEqual(parsed.files[0].viewerViewedState, .unviewed)
    XCTAssertEqual(parsed.files[0].languageHint, .rust)
    XCTAssertNil(parsed.rateLimitSnapshot)
  }
}
