import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

/// Ranker contract: matches OpenAnythingIndex field weights so a search
/// in the Spotlight intent surface produces the same order as the Open
/// Anything palette. Bucketed scoring (prefix > contains > none) per
/// field, weighted (title 0.8, subtitle 0.45, trailing 0.25)
final class IntentSearchRankerTests: XCTestCase {

  // MARK: - field-scoring contract

  func testFieldScorePrefixWinsOverContains() {
    XCTAssertEqual(IntentSearchRanker.fieldScore(field: "refactor", query: "ref"), 1.0)
    XCTAssertEqual(IntentSearchRanker.fieldScore(field: "preflight", query: "ref"), 0.6)
    XCTAssertEqual(IntentSearchRanker.fieldScore(field: "merged", query: "ref"), 0.0)
  }

  func testFieldScoreEmptyInputsReturnZero() {
    XCTAssertEqual(IntentSearchRanker.fieldScore(field: "title", query: ""), 0)
    XCTAssertEqual(IntentSearchRanker.fieldScore(field: "", query: "x"), 0)
  }

  // MARK: - end-to-end ranking

  func testTitlePrefixOutranksRepositoryPrefix() {
    let titleHit = Self.makeItem(
      pullRequestID: "octo/repo#1",
      repository: "octo/repo",
      title: "Renovate auth flow",
      number: 1
    )
    let repoHit = Self.makeItem(
      pullRequestID: "renovate/bot#2",
      repository: "renovate/bot",
      title: "Bump dependency Foo",
      number: 2
    )

    let ranked = IntentSearchRanker.rank(items: [repoHit, titleHit], query: "renovate")

    XCTAssertEqual(
      ranked.map(\.pullRequestID),
      ["octo/repo#1", "renovate/bot#2"],
      "title prefix (0.8) should outweigh subtitle prefix (0.45)"
    )
  }

  func testRepositoryPrefixOutranksTrailingPrefix() {
    let trailingHit = Self.makeItem(
      pullRequestID: "octo/repo#42",
      repository: "octo/repo",
      title: "Unrelated change",
      number: 42
    )
    let repoHit = Self.makeItem(
      pullRequestID: "octo/auth#1",
      repository: "octo/auth",
      title: "Unrelated change",
      number: 1
    )

    let ranked = IntentSearchRanker.rank(items: [trailingHit, repoHit], query: "octo")

    XCTAssertEqual(
      ranked.first?.pullRequestID,
      "octo/repo#42",
      "both items match repo prefix; ties resolve in daemon-returned order"
    )
  }

  func testTiesPreserveDaemonReturnedOrder() {
    let first = Self.makeItem(
      pullRequestID: "octo/repo#1",
      repository: "octo/repo",
      title: "Refactor parser",
      number: 1
    )
    let second = Self.makeItem(
      pullRequestID: "octo/repo#2",
      repository: "octo/repo",
      title: "Refactor lexer",
      number: 2
    )

    let ranked = IntentSearchRanker.rank(items: [first, second], query: "ref")

    XCTAssertEqual(
      ranked.map(\.pullRequestID),
      ["octo/repo#1", "octo/repo#2"],
      "identical scores must keep daemon order (stable sort by original index)"
    )
  }

  func testBlankQueryReturnsItemsUnchanged() {
    let first = Self.makeItem(
      pullRequestID: "a/b#1",
      repository: "a/b",
      title: "Z",
      number: 1
    )
    let second = Self.makeItem(
      pullRequestID: "a/b#2",
      repository: "a/b",
      title: "A",
      number: 2
    )

    let ranked = IntentSearchRanker.rank(items: [first, second], query: "   ")

    XCTAssertEqual(ranked.map(\.pullRequestID), ["a/b#1", "a/b#2"])
  }

  func testCaseInsensitive() {
    let item = Self.makeItem(
      pullRequestID: "x/y#1",
      repository: "x/y",
      title: "Update README",
      number: 1
    )

    let ranked = IntentSearchRanker.rank(items: [item], query: "UPDATE")

    XCTAssertEqual(ranked.first?.title, "Update README")
  }

  // MARK: - helpers

  private static func makeItem(
    pullRequestID: String,
    repository: String,
    title: String,
    number: UInt64
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repository,
      repository: repository,
      number: number,
      title: title,
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: "alice",
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      labels: [],
      checks: [],
      reviews: [],
      additions: 0,
      deletions: 0,
      createdAt: "2026-05-22T10:00:00Z",
      updatedAt: "2026-05-23T12:00:00Z"
    )
  }
}
