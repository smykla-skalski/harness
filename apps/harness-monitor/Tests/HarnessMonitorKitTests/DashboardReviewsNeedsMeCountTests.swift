import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews needs-me count")
struct DashboardReviewsNeedsMeCountTests {
  @Test("count matches the number of items that require attention")
  func countMatchesRequiresAttention() {
    let needsAttention = makeItem(
      id: "pr-attn",
      reviewStatus: .changesRequested
    )
    let policyBlocked = makeItem(id: "pr-policy", policyBlocked: true)
    let mergeConflict = makeItem(id: "pr-conflict", mergeable: .conflicting)
    let failingChecks = makeItem(id: "pr-failing", checkStatus: .failure)
    let calm = makeItem(id: "pr-calm")

    let count = DashboardReviewsRouteView.recomputeNeedsMeCount(items: [
      needsAttention,
      policyBlocked,
      mergeConflict,
      failingChecks,
      calm,
    ])
    #expect(count == 4)
  }

  @Test("empty input returns zero")
  func emptyInputReturnsZero() {
    #expect(DashboardReviewsRouteView.recomputeNeedsMeCount(items: []) == 0)
  }

  @Test("calm items return zero")
  func calmItemsReturnZero() {
    let calm = makeItem(id: "pr-calm")
    #expect(DashboardReviewsRouteView.recomputeNeedsMeCount(items: [calm, calm]) == 0)
  }

  @Test("route source hoists needsMeCount state and wires the on-change update")
  func routeSourceHoistsNeedsMeCountState() throws {
    let routeViewSource = try routeSource(named: "DashboardReviewsRouteView.swift")
    let contentSource = try routeSource(named: "DashboardReviewsRouteView+Content.swift")

    #expect(
      routeViewSource.contains("@State private var needsMeCount: Int = 0"),
      "Needs-Me count must be hoisted into @State to keep it off the body path"
    )
    #expect(routeViewSource.contains("var routeNeedsMeCount: Int"))
    #expect(
      routeViewSource.contains(
        "needsMeCount = DashboardReviewsRouteView.recomputeNeedsMeCount(items: items)"
      ),
      "the items onChange handler must refresh the hoisted needsMeCount"
    )
    #expect(
      contentSource.contains("needsMeCount: routeNeedsMeCount"),
      "the control strip must consume the hoisted state instead of recomputing every body pass"
    )
    #expect(
      !contentSource.contains("routeResponse.items.lazy.filter(\\.requiresAttention).count"),
      "the inline body-path computation must be gone"
    )
  }

  private func makeItem(
    id: String,
    reviewStatus: ReviewReviewStatus = .none,
    checkStatus: ReviewCheckStatus = .success,
    mergeable: ReviewMergeableState = .mergeable,
    policyBlocked: Bool = false
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: id,
      repositoryID: "repo-\(id)",
      repository: "kong/example",
      number: 1,
      title: "Example",
      url: "https://github.com/kong/example/pull/1",
      authorLogin: "renovate[bot]",
      state: .open,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      isDraft: false,
      headSha: "sha-\(id)",
      labels: [],
      additions: 1,
      deletions: 1,
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-05-01T10:00:00Z"
    )
  }

  private func routeSource(named fileName: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      repoRoot
      .appendingPathComponent(
        "apps/harness-monitor/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
