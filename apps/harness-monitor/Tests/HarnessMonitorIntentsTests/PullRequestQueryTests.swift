import Foundation
import HarnessMonitorKit
import XCTest

@testable import HarnessMonitorIntents

final class PullRequestQueryTests: XCTestCase {
  func testEntitiesForReturnsItemsInRequestOrderAndDedupes() async throws {
    let stub = StubPullRequestSource(
      fetchResult: [
        makeItem(pullRequestID: "owner/repo#1", title: "One"),
        makeItem(pullRequestID: "owner/repo#2", title: "Two"),
        makeItem(pullRequestID: "owner/repo#3", title: "Three")
      ]
    )
    let query = PullRequestQuery(source: stub)

    let result = try await query.entities(for: [
      "owner/repo#3", "owner/repo#1", "owner/repo#3"
    ])

    XCTAssertEqual(result.map(\.id), ["owner/repo#3", "owner/repo#1"])
    let recordedFetchIDs = await stub.recordedFetchIDs
    XCTAssertEqual(recordedFetchIDs, [["owner/repo#3", "owner/repo#1"]])
  }

  func testEntitiesForReturnsEmptyForEmptyInput() async throws {
    let stub = StubPullRequestSource()
    let query = PullRequestQuery(source: stub)

    let result = try await query.entities(for: [])

    XCTAssertTrue(result.isEmpty)
    let recorded = await stub.recordedFetchIDs
    XCTAssertTrue(recorded.isEmpty, "should not call the source for empty ids")
  }

  func testSuggestedEntitiesKeepsOnlyItemsThatRequireAttention() async throws {
    let attentionItem = makeItem(
      pullRequestID: "owner/repo#10",
      title: "Needs attention",
      mergeable: .conflicting
    )
    let calmItem = makeItem(pullRequestID: "owner/repo#11", title: "Calm")
    let blockedItem = makeItem(
      pullRequestID: "owner/repo#12",
      title: "Policy blocked",
      policyBlocked: true
    )

    let stub = StubPullRequestSource(
      suggestedResult: [calmItem, attentionItem, blockedItem]
    )
    let query = PullRequestQuery(source: stub)

    let result = try await query.suggestedEntities()

    XCTAssertEqual(result.map(\.id), ["owner/repo#10", "owner/repo#12"])
    let recordedSuggestedLimits = await stub.recordedSuggestedLimits
    XCTAssertEqual(recordedSuggestedLimits, [PullRequestQuery.suggestedLimit])
  }

  func testEntitiesMatchingFallsBackToSuggestedWhenQueryBlank() async throws {
    let stub = StubPullRequestSource(
      suggestedResult: [
        makeItem(pullRequestID: "owner/repo#20", title: "Match me", mergeable: .conflicting)
      ]
    )
    let query = PullRequestQuery(source: stub)

    let result = try await query.entities(matching: "   ")

    XCTAssertEqual(result.map(\.id), ["owner/repo#20"])
    let suggestedHits = await stub.recordedSuggestedLimits
    let searchHits = await stub.recordedSearches
    XCTAssertEqual(suggestedHits.count, 1, "blank query should hit suggested, not search")
    XCTAssertTrue(searchHits.isEmpty)
  }

  func testEntitiesMatchingDelegatesToSearchWhenQueryNonEmpty() async throws {
    let stub = StubPullRequestSource(
      searchResult: [
        makeItem(pullRequestID: "owner/repo#30", title: "Renovate"),
        makeItem(pullRequestID: "owner/repo#31", title: "Renovate again")
      ]
    )
    let query = PullRequestQuery(source: stub)

    let result = try await query.entities(matching: "  Renovate  ")

    XCTAssertEqual(result.map(\.id), ["owner/repo#30", "owner/repo#31"])
    let searches = await stub.recordedSearches
    XCTAssertEqual(searches.count, 1)
    XCTAssertEqual(searches.first?.query, "Renovate")
    XCTAssertEqual(searches.first?.limit, PullRequestQuery.searchLimit)
  }

  // MARK: - helpers

  private func makeItem(
    pullRequestID: String,
    title: String,
    mergeable: ReviewMergeableState = .mergeable,
    policyBlocked: Bool = false
  ) -> ReviewItem {
    let parts = pullRequestID.components(separatedBy: "#")
    let repo = parts.first ?? "owner/repo"
    let number = UInt64(parts.count > 1 ? parts[1] : "0") ?? 0
    return ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repo,
      repository: repo,
      number: number,
      title: title,
      url: "https://github.com/\(repo)/pull/\(number)",
      authorLogin: "alice",
      state: .open,
      mergeable: mergeable,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: policyBlocked,
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

actor StubPullRequestSource: PullRequestSource {
  private let fetchResult: [ReviewItem]
  private let suggestedResult: [ReviewItem]
  private let searchResult: [ReviewItem]
  private(set) var recordedFetchIDs: [[String]] = []
  private(set) var recordedSuggestedLimits: [Int] = []
  private(set) var recordedSearches: [(query: String, limit: Int)] = []

  init(
    fetchResult: [ReviewItem] = [],
    suggestedResult: [ReviewItem] = [],
    searchResult: [ReviewItem] = []
  ) {
    self.fetchResult = fetchResult
    self.suggestedResult = suggestedResult
    self.searchResult = searchResult
  }

  func fetch(ids: [String]) async throws -> [ReviewItem] {
    recordedFetchIDs.append(ids)
    return fetchResult
  }

  func suggested(limit: Int) async throws -> [ReviewItem] {
    recordedSuggestedLimits.append(limit)
    return suggestedResult
  }

  func search(query: String, limit: Int) async throws -> [ReviewItem] {
    recordedSearches.append((query: query, limit: limit))
    return searchResult
  }
}
