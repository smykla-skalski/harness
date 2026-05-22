import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependency diagnostics")
struct DashboardDependencyDiagnosticsTests {
  @Test("activity snapshot exports dependency action diagnostics")
  func activitySnapshotExportsDependencyActionDiagnostics() {
    let entry = DashboardDependencyActivityEntry(
      title: "Rerunning",
      summary: "Rerun failed",
      outcome: .failure,
      messages: ["Missing suite"]
    )
    let snapshot = DashboardDependencyActivitySnapshot(
      pullRequestID: "pr-1",
      isRefreshing: false,
      actionTitle: nil,
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      lastAction: entry,
      missingCheckRunURLCount: 1,
      totalCheckCount: 2
    )

    #expect(snapshot.diagnosticsText.contains("Pull request ID: pr-1"))
    #expect(snapshot.diagnosticsText.contains("Outcome: failure"))
    #expect(snapshot.diagnosticsText.contains("Message: Missing suite"))
  }

  @Test("fix CI body includes failed checks and activity context")
  func fixCIBodyIncludesFailedChecksAndActivityContext() {
    let failed = DependencyUpdateCheck(
      name: "Test",
      status: .completed,
      conclusion: .failure,
      checkSuiteID: "suite-test",
      detailsURL: "https://github.com/org-a/example/actions/runs/1"
    )
    let passing = DependencyUpdateCheck(
      name: "CodeQL",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-codeql",
      detailsURL: "https://github.com/org-a/example/actions/runs/2"
    )
    let item = dependencyItem(checks: [failed, passing])
    let activity = DashboardDependencyActivitySnapshot(
      pullRequestID: item.pullRequestID,
      isRefreshing: false,
      actionTitle: nil,
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      lastAction: DashboardDependencyActivityEntry(
        title: "Rerunning",
        summary: "Rerun failed",
        outcome: .failure
      ),
      missingCheckRunURLCount: 1,
      totalCheckCount: 2
    )

    let body = dashboardDependencyFixCIBody(for: item, activity: activity)

    #expect(body.contains("Head SHA: abc123"))
    #expect(body.contains("Missing check run links: 1/2"))
    #expect(body.contains("Test: Failure https://github.com/org-a/example/actions/runs/1"))
    #expect(!body.contains("CodeQL: Success"))
    #expect(body.contains("Recent dependency action:"))
  }

  private func dependencyItem(checks: [DependencyUpdateCheck]) -> DependencyUpdateItem {
    DependencyUpdateItem(
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
