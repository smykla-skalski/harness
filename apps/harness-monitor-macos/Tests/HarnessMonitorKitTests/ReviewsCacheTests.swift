import Foundation
import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class ReviewsCacheTests: XCTestCase {
  func testPreferencesHashIgnoresFreshnessAndOrder() {
    let lhs = ReviewsQueryRequest(
      authors: ["renovate[bot]", "dependabot[bot]"],
      organizations: ["acme"],
      repositories: ["acme/api"],
      excludeRepositories: ["acme/archive"],
      forceRefresh: false,
      cacheMaxAgeSeconds: 600
    )
    let rhs = ReviewsQueryRequest(
      authors: ["dependabot[bot]", "renovate[bot]"],
      organizations: ["acme"],
      repositories: ["acme/api"],
      excludeRepositories: ["acme/archive"],
      forceRefresh: true,
      cacheMaxAgeSeconds: 30
    )
    XCTAssertEqual(
      ReviewsCache.preferencesHash(for: lhs),
      ReviewsCache.preferencesHash(for: rhs)
    )
  }

  func testPreferencesHashChangesWhenBucketChanges() {
    let base = ReviewsQueryRequest(authors: ["renovate[bot]"])
    let widened = ReviewsQueryRequest(authors: ["renovate[bot]", "dependabot[bot]"])
    XCTAssertNotEqual(
      ReviewsCache.preferencesHash(for: base),
      ReviewsCache.preferencesHash(for: widened)
    )
  }

  func testSaveAndLoadRoundTrip() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_1"),
      makeItem(pullRequestID: "pr_2"),
    ])

    cache.save(preferencesHash: "alpha", response: response)
    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))
    XCTAssertEqual(loaded.items.map(\.pullRequestID), ["pr_1", "pr_2"])
    XCTAssertEqual(loaded.summary.total, 2)
  }

  func testSaveAndLoadCollapseDuplicatePullRequestIDs() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    let response = makeResponse(items: [
      makeItem(
        pullRequestID: "pr_1",
        reviewStatus: .reviewRequired,
        updatedAt: "2026-05-20T12:00:00Z"
      ),
      makeItem(
        pullRequestID: "pr_1",
        reviewStatus: .approved,
        updatedAt: "2026-05-21T12:00:00Z"
      ),
    ])

    cache.save(preferencesHash: "alpha", response: response)
    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))

    XCTAssertEqual(loaded.items.map(\.pullRequestID), ["pr_1"])
    XCTAssertEqual(loaded.items[0].reviewStatus, .approved)
    XCTAssertEqual(loaded.summary.total, 1)
  }

  func testDecodingResponseCollapsesDuplicatePullRequestIDs() throws {
    let encoder = JSONEncoder()
    let first = makeItem(
      pullRequestID: "pr_1",
      reviewStatus: .reviewRequired,
      updatedAt: "2026-05-20T12:00:00Z"
    )
    let second = makeItem(
      pullRequestID: "pr_1",
      reviewStatus: .approved,
      updatedAt: "2026-05-21T12:00:00Z"
    )

    let firstObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try encoder.encode(first)) as? [String: Any]
    )
    let secondObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: try encoder.encode(second)) as? [String: Any]
    )
    let payload: [String: Any] = [
      "fetchedAt": "2026-05-21T12:00:00Z",
      "fromCache": true,
      "summary": [
        "total": 2,
        "reviewRequired": 2,
        "readyToMerge": 0,
        "autoApprovable": 0,
        "waitingOnChecks": 0,
        "blocked": 2,
      ],
      "items": [firstObject, secondObject],
      "repositoryLabels": [:],
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try JSONDecoder().decode(ReviewsQueryResponse.self, from: data)

    XCTAssertEqual(decoded.items.map(\.pullRequestID), ["pr_1"])
    XCTAssertEqual(decoded.items[0].reviewStatus, .approved)
    XCTAssertEqual(decoded.summary.total, 1)
  }

  func testSaveReplacesPriorSnapshotAndDropsAbsentItems() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_1"),
        makeItem(pullRequestID: "pr_2"),
        makeItem(pullRequestID: "pr_3"),
      ])
    )
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_1")
      ])
    )

    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))
    XCTAssertEqual(loaded.items.map(\.pullRequestID), ["pr_1"])
    XCTAssertEqual(rowCount(in: context), 1, "Wholesale replace must not multiply rows")
  }

  func testSnapshotsAreIsolatedByPreferencesHash() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [makeItem(pullRequestID: "pr_1")])
    )
    cache.save(
      preferencesHash: "beta",
      response: makeResponse(items: [makeItem(pullRequestID: "pr_99")])
    )

    XCTAssertEqual(
      cache.load(preferencesHash: "alpha")?.items.map(\.pullRequestID),
      ["pr_1"]
    )
    XCTAssertEqual(
      cache.load(preferencesHash: "beta")?.items.map(\.pullRequestID),
      ["pr_99"]
    )
    XCTAssertEqual(rowCount(in: context), 2)
  }

  func testApplyRefreshReplacesMatchingOpenItem() {
    let cached = [
      makeItem(pullRequestID: "pr_1", reviewStatus: .reviewRequired),
      makeItem(pullRequestID: "pr_2", reviewStatus: .reviewRequired),
    ]
    let refresh = ReviewsRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      items: [makeItem(pullRequestID: "pr_1", reviewStatus: .approved)]
    )

    let result = ReviewsCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].reviewStatus, .approved)
    XCTAssertEqual(result[1].reviewStatus, .reviewRequired)
  }

  func testApplyRefreshDropsMergedAndClosedItems() {
    let cached = [
      makeItem(pullRequestID: "pr_1"),
      makeItem(pullRequestID: "pr_2"),
    ]
    let refresh = ReviewsRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      items: [makeItem(pullRequestID: "pr_1", state: .merged)]
    )

    let result = ReviewsCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.map(\.pullRequestID), ["pr_2"])
  }

  func testApplyRefreshDropsMissingIDs() {
    let cached = [
      makeItem(pullRequestID: "pr_1"),
      makeItem(pullRequestID: "pr_2"),
    ]
    let refresh = ReviewsRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      missingPullRequestIDs: ["pr_1"]
    )

    let result = ReviewsCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.map(\.pullRequestID), ["pr_2"])
  }

  func testApplyRefreshPersistsReconciledSnapshot() throws {
    let context = try makeContext()
    let cache = ReviewsCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_1"),
        makeItem(pullRequestID: "pr_2"),
        makeItem(pullRequestID: "pr_3"),
      ])
    )
    let refresh = ReviewsRefreshResponse(
      fetchedAt: "2026-05-21T11:00:00Z",
      items: [makeItem(pullRequestID: "pr_2", state: .closed)],
      missingPullRequestIDs: ["pr_1"]
    )

    let reconciled = try XCTUnwrap(
      cache.applyRefresh(preferencesHash: "alpha", refresh: refresh)
    )
    XCTAssertEqual(reconciled.items.map(\.pullRequestID), ["pr_3"])
    XCTAssertEqual(reconciled.fetchedAt, "2026-05-21T11:00:00Z")
    XCTAssertEqual(reconciled.summary.total, 1)

    let loaded = try XCTUnwrap(cache.load(preferencesHash: "alpha"))
    XCTAssertEqual(loaded.items.map(\.pullRequestID), ["pr_3"])
  }

  func testApplyRefreshReturnsNilWhenNoSnapshotExists() {
    let context = try? makeContext()
    guard let context else {
      XCTFail("Failed to build context")
      return
    }
    let cache = ReviewsCache(context: context)
    let refresh = ReviewsRefreshResponse(
      fetchedAt: "2026-05-21T11:00:00Z",
      items: [makeItem(pullRequestID: "pr_1")]
    )
    XCTAssertNil(cache.applyRefresh(preferencesHash: "missing", refresh: refresh))
  }

  // MARK: - Helpers

  private func makeContext() throws -> ModelContext {
    let container = try HarnessMonitorModelContainer.preview()
    return ModelContext(container)
  }

  private func rowCount(in context: ModelContext) -> Int {
    (try? context.fetch(FetchDescriptor<CachedReviewsSnapshot>()).count) ?? -1
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
