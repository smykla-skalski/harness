import Foundation

@testable import HarnessMonitorKit

func dashboardReviewsRouteSource() throws -> String {
  try dashboardReviewsRouteSource(named: "DashboardReviewsRouteView.swift")
}

func dashboardReviewsRouteSource(named fileName: String) throws -> String {
  let repoRoot = dashboardReviewsRepoRoot()
  let sourceURL =
    repoRoot
    .appendingPathComponent(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
    )
    .appendingPathComponent(fileName)
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

func dashboardReviewsRoutePreviewSource(named fileName: String) throws -> String {
  let repoRoot = dashboardReviewsRepoRoot()
  let sourceURL =
    repoRoot
    .appendingPathComponent(
      "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard/Previews"
    )
    .appendingPathComponent(fileName)
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

func dashboardReviewsAppSource(_ relativePath: String) throws -> String {
  let sourceURL = dashboardReviewsRepoRoot().appendingPathComponent(relativePath)
  return try String(contentsOf: sourceURL, encoding: .utf8)
}

func dashboardReviewsTestReviewItem(
  checkStatus: ReviewCheckStatus,
  checks: [ReviewCheck]
) -> ReviewItem {
  ReviewItem(
    pullRequestID: "pr-1",
    repositoryID: "repo-1",
    repository: "org-a/example",
    number: 42,
    title: "Bump dependency",
    url: "https://github.com/org-a/example/pull/42",
    authorLogin: "renovate[bot]",
    state: .open,
    mergeable: .mergeable,
    reviewStatus: .reviewRequired,
    checkStatus: checkStatus,
    policyBlocked: false,
    isDraft: false,
    headSha: "abc123",
    checks: checks,
    additions: 10,
    deletions: 4,
    createdAt: "2026-05-20T10:00:00Z",
    updatedAt: "2026-05-20T11:00:00Z"
  )
}

private func dashboardReviewsRepoRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}
