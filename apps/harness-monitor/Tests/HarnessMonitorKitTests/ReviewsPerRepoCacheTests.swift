import Foundation
import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class ReviewsPerRepoCacheTests: XCTestCase {
  func testApplyPerRepoResponseLeavesOtherReposUntouched() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api"),
    ]
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api", reviewStatus: .approved)
    ])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    let webItems = result.filter { $0.repository == "acme/web" }
    XCTAssertEqual(webItems.map(\.pullRequestID), ["pr_w1"])
    XCTAssertEqual(webItems.first?.reviewStatus, .reviewRequired)
  }

  func testApplyPerRepoResponseReplacesOpenItemsForTargetedRepo() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api", reviewStatus: .reviewRequired),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api", reviewStatus: .reviewRequired),
    ]
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api", reviewStatus: .approved),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api", reviewStatus: .reviewRequired),
    ])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_a1", "pr_a2"])
    XCTAssertEqual(result[0].reviewStatus, .approved)
    XCTAssertEqual(result[1].reviewStatus, .reviewRequired)
  }

  func testApplyPerRepoResponseCollapsesDuplicateCachedIDs() {
    let cached = [
      makeItem(
        pullRequestID: "pr_a1",
        repository: "acme/api",
        reviewStatus: .reviewRequired,
        updatedAt: "2026-05-20T12:00:00Z"
      ),
      makeItem(
        pullRequestID: "pr_a1",
        repository: "acme/api",
        reviewStatus: .reviewRequired,
        updatedAt: "2026-05-20T12:30:00Z"
      ),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
    ]
    let response = makeResponse(items: [
      makeItem(
        pullRequestID: "pr_a1",
        repository: "acme/api",
        reviewStatus: .approved,
        updatedAt: "2026-05-21T12:00:00Z"
      )
    ])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_a1", "pr_w1"])
    XCTAssertEqual(result[0].reviewStatus, .approved)
  }

  func testApplyPerRepoResponseDropsMissingItemsForTargetedRepo() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api"),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
    ]
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api")
    ])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_a1", "pr_w1"])
  }

  func testApplyPerRepoResponseAppendsNewlyDiscoveredPRs() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
    ]
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_a_new", repository: "acme/api"),
    ])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_a1", "pr_w1", "pr_a_new"])
  }

  func testApplyPerRepoResponseEmptyResponseDropsAllRepoItems() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api"),
    ]
    let response = makeResponse(items: [])

    let result = ReviewsCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_w1"])
  }

  func testApplyPerRepoResponsePersistsAndReturnsReconciledSnapshot() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
        makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
      ])
    )

    let response = ReviewsQueryResponse(
      fetchedAt: "2026-05-21T12:00:00Z",
      fromCache: false,
      summary: ReviewsSummary(items: []),
      items: [makeItem(pullRequestID: "pr_a_new", repository: "acme/api")]
    )
    let reconciled = try XCTUnwrap(
      cache.applyPerRepoResponse(
        preferencesHash: "alpha",
        repository: "acme/api",
        response: response
      )
    )

    XCTAssertEqual(
      reconciled.items.map(\.pullRequestID).sorted(),
      ["pr_a_new", "pr_w1"]
    )
    XCTAssertEqual(reconciled.fetchedAt, "2026-05-21T12:00:00Z")
    XCTAssertEqual(reconciled.summary.total, 2)

    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))
    XCTAssertEqual(loaded.items.map(\.pullRequestID).sorted(), ["pr_a_new", "pr_w1"])
  }

  func testApplyPerRepoResponseReturnsNilWhenNoSnapshotExists() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api")
    ])
    XCTAssertNil(
      cache.applyPerRepoResponse(
        preferencesHash: "missing",
        repository: "acme/api",
        response: response
      )
    )
  }

  func testApplyPerRepoResponsePreservesLabelsWhenResponseLabelsEmpty() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    let seededLabels = [
      ReviewRepositoryLabel(name: "bug", color: "d73a4a", description: nil),
      ReviewRepositoryLabel(name: "release", color: "0e8a16", description: nil),
    ]
    cache.save(
      preferencesHash: "alpha",
      response: ReviewsQueryResponse(
        fetchedAt: "2026-05-21T10:00:00Z",
        fromCache: false,
        summary: ReviewsSummary(
          items: [makeItem(pullRequestID: "pr_a1", repository: "acme/api")]
        ),
        items: [makeItem(pullRequestID: "pr_a1", repository: "acme/api")],
        repositoryLabels: ["acme/api": seededLabels]
      )
    )

    let response = ReviewsQueryResponse(
      fetchedAt: "2026-05-21T12:00:00Z",
      fromCache: false,
      summary: ReviewsSummary(
        items: [makeItem(pullRequestID: "pr_a1", repository: "acme/api")]
      ),
      items: [makeItem(pullRequestID: "pr_a1", repository: "acme/api")],
      repositoryLabels: ["acme/api": []]
    )
    let reconciled = try XCTUnwrap(
      cache.applyPerRepoResponse(
        preferencesHash: "alpha",
        repository: "acme/api",
        response: response
      )
    )

    XCTAssertEqual(reconciled.repositoryLabels["acme/api"], seededLabels)
    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))
    XCTAssertEqual(loaded.repositoryLabels["acme/api"], seededLabels)
  }

  // MARK: - Helpers

  private func makeContext() throws -> ModelContext {
    let container = try HarnessMonitorModelContainer.preview()
    return ModelContext(container)
  }

  private func makeResponse(items: [ReviewItem]) -> ReviewsQueryResponse {
    ReviewsQueryResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      fromCache: false,
      summary: ReviewsSummary(items: items),
      items: items
    )
  }

  private func makeItem(
    pullRequestID: String,
    repository: String = "acme/api",
    state: ReviewPullRequestState = .open,
    reviewStatus: ReviewReviewStatus = .reviewRequired,
    updatedAt: String = "2026-05-20T12:00:00Z"
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: "\(repository)#node",
      repository: repository,
      number: 1,
      title: "chore(deps): bump",
      url: "https://example.com",
      authorLogin: "renovate[bot]",
      state: state,
      mergeable: .mergeable,
      reviewStatus: reviewStatus,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-20T12:00:00Z",
      updatedAt: updatedAt
    )
  }
}
