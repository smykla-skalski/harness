import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review diagnostics")
struct DashboardReviewDiagnosticsTests {
  @Test("activity snapshot exports review action diagnostics")
  func activitySnapshotExportsReviewActionDiagnostics() {
    let entry = DashboardReviewActivityEntry(
      title: "Rerunning",
      summary: "Rerun failed",
      outcome: .failure,
      messages: ["Missing suite"]
    )
    let snapshot = DashboardReviewActivitySnapshot(
      pullRequestID: "pr-1",
      isRefreshing: false,
      actionTitle: nil,
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      lastAction: entry,
      policyStatus: nil,
      missingCheckRunURLCount: 1,
      totalCheckCount: 2,
      capabilities: ReviewsCapabilitiesResponse()
    )

    #expect(snapshot.diagnosticsText.contains("Pull request ID: pr-1"))
    #expect(snapshot.diagnosticsText.contains("Outcome: failure"))
    #expect(snapshot.diagnosticsText.contains("Message: Missing suite"))
  }

  @Test("fix CI body includes failed checks and activity context")
  func fixCIBodyIncludesFailedChecksAndActivityContext() {
    let failed = ReviewCheck(
      name: "Test",
      status: .completed,
      conclusion: .failure,
      checkSuiteID: "suite-test",
      detailsURL: "https://github.com/org-a/example/actions/runs/1"
    )
    let passing = ReviewCheck(
      name: "CodeQL",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-codeql",
      detailsURL: "https://github.com/org-a/example/actions/runs/2"
    )
    let item = reviewItem(checks: [failed, passing])
    let activity = DashboardReviewActivitySnapshot(
      pullRequestID: item.pullRequestID,
      isRefreshing: false,
      actionTitle: nil,
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      lastAction: DashboardReviewActivityEntry(
        title: "Rerunning",
        summary: "Rerun failed",
        outcome: .failure
      ),
      policyStatus: nil,
      missingCheckRunURLCount: 1,
      totalCheckCount: 2,
      capabilities: ReviewsCapabilitiesResponse()
    )

    let body = dashboardReviewFixCIBody(for: item, activity: activity)

    #expect(body.contains("Head SHA: abc123"))
    #expect(body.contains("Missing check run links: 1/2"))
    #expect(body.contains("Test: Failure https://github.com/org-a/example/actions/runs/1"))
    #expect(!body.contains("CodeQL: Success"))
    #expect(body.contains("Recent review action:"))
  }

  private func reviewItem(checks: [ReviewCheck]) -> ReviewItem {
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
      checkStatus: .failure,
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
}
