import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews search index order independence")
struct DashboardReviewsSearchIndexOrderIndependenceTests {
  @Test("reordering items yields the same signature")
  func reorderingItemsYieldsSameSignature() {
    let one = makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios")
    let two = makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react")
    let three = makeItem(id: "pr-3", repository: "kong/c", number: 3, title: "Bump lodash")

    let ascending = dashboardReviewsSearchIndexSignature(items: [one, two, three])
    let descending = dashboardReviewsSearchIndexSignature(items: [three, two, one])
    let shuffled = dashboardReviewsSearchIndexSignature(items: [two, one, three])

    #expect(ascending == descending)
    #expect(ascending == shuffled)
  }

  @Test("changing item content changes the signature")
  func changingItemContentChangesSignature() {
    let baseline = [
      makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios"),
      makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react"),
    ]
    let renamedTitle = [
      makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios v2"),
      makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react"),
    ]
    let differentRepo = [
      makeItem(id: "pr-1", repository: "kong/zzz", number: 1, title: "Bump axios"),
      makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react"),
    ]
    let differentLabels = [
      makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios", labels: ["a"]),
      makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react"),
    ]

    let baselineSignature = dashboardReviewsSearchIndexSignature(items: baseline)
    #expect(baselineSignature != dashboardReviewsSearchIndexSignature(items: renamedTitle))
    #expect(baselineSignature != dashboardReviewsSearchIndexSignature(items: differentRepo))
    #expect(baselineSignature != dashboardReviewsSearchIndexSignature(items: differentLabels))
  }

  @Test("count and empty-input signatures are stable")
  func countAndEmptyInputSignaturesAreStable() {
    let empty = dashboardReviewsSearchIndexSignature(items: [])
    #expect(empty == DashboardReviewsSearchIndexSignature(count: 0, contentFingerprint: 0))
    #expect(empty.contentFingerprint == 0)

    let one = dashboardReviewsSearchIndexSignature(items: [
      makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios")
    ])
    #expect(one.count == 1)
  }

  @Test("adding an item changes the signature")
  func addingAnItemChangesSignature() {
    let one = makeItem(id: "pr-1", repository: "kong/a", number: 1, title: "Bump axios")
    let two = makeItem(id: "pr-2", repository: "kong/b", number: 2, title: "Bump react")

    let single = dashboardReviewsSearchIndexSignature(items: [one])
    let pair = dashboardReviewsSearchIndexSignature(items: [one, two])
    #expect(single != pair)
    #expect(pair.count == 2)
  }

  @Test("toolbar search task identity uses route response revision")
  func toolbarSearchTaskIdentityUsesRouteResponseRevision() throws {
    let routeSource = try dashboardReviewsRouteSource()
    let toolbarSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ToolbarSearch.swift")

    #expect(routeSource.contains("itemsVersion: routeResponseItemsVersion"))
    #expect(toolbarSource.contains("let itemsVersion: DashboardReviewsItemsVersion"))
    #expect(toolbarSource.contains("itemsVersion: request.itemsVersion"))
    #expect(!toolbarSource.contains("dashboardReviewsSearchIndexSignature(items: items)"))
  }

  @Test("toolbar search worker builds the fuzzy index lazily")
  func toolbarSearchWorkerBuildsIndexLazily() throws {
    let toolbarSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ToolbarSearch.swift")
    let workerSource = sourceSlice(
      toolbarSource,
      from: "private actor DashboardReviewsSearchWorker",
      to: "// Build an order-independent signature"
    )

    #expect(workerSource.contains("private var searchIndex: DashboardReviewsSearchIndex?"))
    #expect(workerSource.contains("searchIndex == nil"))
    #expect(workerSource.contains("guard let searchIndex else"))
    #expect(!workerSource.contains("DashboardReviewsSearchIndex(items: [])"))
  }

  private func makeItem(
    id: String,
    repository: String,
    number: UInt64,
    title: String,
    authorLogin: String = "renovate[bot]",
    labels: [String] = ["dependencies"]
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: id,
      repositoryID: "repo-\(repository)",
      repository: repository,
      number: number,
      title: title,
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: authorLogin,
      state: .open,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .success,
      policyBlocked: false,
      isDraft: false,
      headSha: "sha-\(id)",
      labels: labels,
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-05-01T10:00:00Z"
    )
  }
}
