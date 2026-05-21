import Foundation
import SwiftData
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class DependencyUpdatesCacheTests: XCTestCase {
  func testPreferencesHashIgnoresFreshnessAndOrder() {
    let lhs = DependencyUpdatesQueryRequest(
      authors: ["renovate[bot]", "dependabot[bot]"],
      organizations: ["acme"],
      repositories: ["acme/api"],
      excludeRepositories: ["acme/archive"],
      forceRefresh: false,
      cacheMaxAgeSeconds: 600
    )
    let rhs = DependencyUpdatesQueryRequest(
      authors: ["dependabot[bot]", "renovate[bot]"],
      organizations: ["acme"],
      repositories: ["acme/api"],
      excludeRepositories: ["acme/archive"],
      forceRefresh: true,
      cacheMaxAgeSeconds: 30
    )
    XCTAssertEqual(
      DependencyUpdatesCache.preferencesHash(for: lhs),
      DependencyUpdatesCache.preferencesHash(for: rhs)
    )
  }

  func testPreferencesHashChangesWhenBucketChanges() {
    let base = DependencyUpdatesQueryRequest(authors: ["renovate[bot]"])
    let widened = DependencyUpdatesQueryRequest(authors: ["renovate[bot]", "dependabot[bot]"])
    XCTAssertNotEqual(
      DependencyUpdatesCache.preferencesHash(for: base),
      DependencyUpdatesCache.preferencesHash(for: widened)
    )
  }

  func testSaveAndLoadRoundTrip() throws {
    let context = try makeContext()
    let cache = DependencyUpdatesCache(context: context)
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
    let cache = DependencyUpdatesCache(context: context)
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
    let decoded = try JSONDecoder().decode(DependencyUpdatesQueryResponse.self, from: data)

    XCTAssertEqual(decoded.items.map(\.pullRequestID), ["pr_1"])
    XCTAssertEqual(decoded.items[0].reviewStatus, .approved)
    XCTAssertEqual(decoded.summary.total, 1)
  }

  func testSaveReplacesPriorSnapshotAndDropsAbsentItems() throws {
    let context = try makeContext()
    let cache = DependencyUpdatesCache(context: context)
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
    let cache = DependencyUpdatesCache(context: context)
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
    let refresh = DependencyUpdatesRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      items: [makeItem(pullRequestID: "pr_1", reviewStatus: .approved)]
    )

    let result = DependencyUpdatesCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[0].reviewStatus, .approved)
    XCTAssertEqual(result[1].reviewStatus, .reviewRequired)
  }

  func testApplyRefreshDropsMergedAndClosedItems() {
    let cached = [
      makeItem(pullRequestID: "pr_1"),
      makeItem(pullRequestID: "pr_2"),
    ]
    let refresh = DependencyUpdatesRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      items: [makeItem(pullRequestID: "pr_1", state: .merged)]
    )

    let result = DependencyUpdatesCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.map(\.pullRequestID), ["pr_2"])
  }

  func testApplyRefreshDropsMissingIDs() {
    let cached = [
      makeItem(pullRequestID: "pr_1"),
      makeItem(pullRequestID: "pr_2"),
    ]
    let refresh = DependencyUpdatesRefreshResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      missingPullRequestIDs: ["pr_1"]
    )

    let result = DependencyUpdatesCache.applyRefreshToItems(cached, refresh: refresh)
    XCTAssertEqual(result.map(\.pullRequestID), ["pr_2"])
  }

  func testApplyRefreshPersistsReconciledSnapshot() throws {
    let context = try makeContext()
    let cache = DependencyUpdatesCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_1"),
        makeItem(pullRequestID: "pr_2"),
        makeItem(pullRequestID: "pr_3"),
      ])
    )
    let refresh = DependencyUpdatesRefreshResponse(
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
    let cache = DependencyUpdatesCache(context: context)
    let refresh = DependencyUpdatesRefreshResponse(
      fetchedAt: "2026-05-21T11:00:00Z",
      items: [makeItem(pullRequestID: "pr_1")]
    )
    XCTAssertNil(cache.applyRefresh(preferencesHash: "missing", refresh: refresh))
  }

  // MARK: - applyPerRepoResponse

  func testApplyPerRepoResponseLeavesOtherReposUntouched() {
    let cached = [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
      makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
      makeItem(pullRequestID: "pr_a2", repository: "acme/api"),
    ]
    let response = makeResponse(items: [
      makeItem(pullRequestID: "pr_a1", repository: "acme/api", reviewStatus: .approved)
    ])

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
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

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
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
      ),
    ])

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
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

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
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

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
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

    let result = DependencyUpdatesCache.applyPerRepoResponseToItems(
      cached,
      repository: "acme/api",
      response: response
    )

    XCTAssertEqual(result.map(\.pullRequestID), ["pr_w1"])
  }

  func testApplyPerRepoResponsePersistsAndReturnsReconciledSnapshot() throws {
    let context = try makeContext()
    let cache = DependencyUpdatesCache(context: context)
    cache.save(
      preferencesHash: "alpha",
      response: makeResponse(items: [
        makeItem(pullRequestID: "pr_a1", repository: "acme/api"),
        makeItem(pullRequestID: "pr_w1", repository: "acme/web"),
      ])
    )

    let response = DependencyUpdatesQueryResponse(
      fetchedAt: "2026-05-21T12:00:00Z",
      fromCache: false,
      summary: DependencyUpdatesSummary(items: []),
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
    let cache = DependencyUpdatesCache(context: context)
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

  // MARK: - Helpers

  private func makeContext() throws -> ModelContext {
    let container = try HarnessMonitorModelContainer.preview()
    return ModelContext(container)
  }

  private func rowCount(in context: ModelContext) -> Int {
    (try? context.fetch(FetchDescriptor<CachedDependencyUpdatesSnapshot>()).count) ?? -1
  }

  private func makeResponse(items: [DependencyUpdateItem]) -> DependencyUpdatesQueryResponse {
    DependencyUpdatesQueryResponse(
      fetchedAt: "2026-05-21T10:00:00Z",
      fromCache: false,
      summary: DependencyUpdatesSummary(items: items),
      items: items
    )
  }

  private func makeItem(
    pullRequestID: String,
    repository: String = "acme/api",
    state: DependencyUpdatePullRequestState = .open,
    reviewStatus: DependencyUpdateReviewStatus = .reviewRequired,
    updatedAt: String = "2026-05-20T12:00:00Z"
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
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
