import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews route view")
struct DashboardReviewsRouteViewTests {
  @Test("missing-client state keeps the route loading while the daemon connects")
  func missingClientStateKeepsLoadingWhileConnecting() {
    #expect(
      dashboardReviewsMissingClientState(
        backgroundRefresh: false,
        connectionState: .connecting
      ) == .loading
    )
    #expect(
      dashboardReviewsMissingClientState(
        backgroundRefresh: true,
        connectionState: .connecting
      ) == .ignore
    )
    #expect(
      dashboardReviewsMissingClientState(
        backgroundRefresh: false,
        connectionState: .idle
      ) == .error("The reviews route needs a daemon client")
    )
    #expect(
      dashboardReviewsMissingClientState(
        backgroundRefresh: false,
        connectionState: .offline("Daemon stopped")
      ) == .error("The reviews route needs a daemon client")
    )
  }

  @Test("reload task key changes when connection state changes")
  func reloadTaskKeyChangesWhenConnectionStateChanges() {
    let idle = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      connectionState: .idle
    )
    let connecting = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      connectionState: .connecting
    )
    let online = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      connectionState: .online
    )

    #expect(idle != connecting)
    #expect(connecting != online)
  }

  @Test("route source reloads from the connection-aware task key")
  func reloadTaskKeyChangesWhenPreferencesSignatureChanges() {
    let first = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=a",
      connectionState: .online
    )
    let second = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=b",
      connectionState: .online
    )

    #expect(first != second)
  }

  @Test("route source caches decoded preferences off the SwiftUI body path")
  func routeSourceCachesDecodedPreferencesOffTheSwiftUIBodyPath() throws {
    let source = try routeSource()
    let supportSource = try routeSource(named: "DashboardReviewsRouteSupport.swift")
    let cacheSource = try routeSource(named: "DashboardReviewsRouteView+Cache.swift")
    let schedulerSource = try routeSource(named: "DashboardReviewsRouteView+Scheduler.swift")

    #expect(supportSource.contains("struct DashboardReviewsResolvedPreferences"))
    #expect(source.contains("@State private var resolvedPreferences"))
    #expect(
      source.contains("var routeResolvedPreferences: DashboardReviewsResolvedPreferences"))
    #expect(source.contains(".onChange(of: storedPreferences, initial: true)"))
    #expect(source.contains("syncPreferencesFromStorage(newValue)"))
    #expect(
      !source.contains("get { DashboardReviewsPreferences.decode(from: storedPreferences) }"))
    #expect(
      !source.contains(
        "var normalizedPreferences: DashboardReviewsPreferences {\n    preferences.normalized()"
      )
    )
    #expect(cacheSource.contains("routeResolvedPreferences.cacheHash"))
    #expect(schedulerSource.contains("explicitRepositories: preferences.repositories"))
    #expect(schedulerSource.contains("preferences: preferences"))
  }

  @Test("route presentation input consumes toolbar search text")
  func routePresentationInputConsumesToolbarSearchText() throws {
    let source = try routeSource()

    #expect(source.contains("searchText: searchText"))
    #expect(!source.contains("searchText: \"\""))
  }

  @Test("route source keeps review network decode off the view actor")
  func routeSourceKeepsReviewNetworkDecodeOffTheViewActor() throws {
    let supportSource = try routeSource(named: "DashboardReviewsRouteSupport.swift")
    let refreshSource = try routeSource(named: "DashboardReviewsRouteView+Refresh.swift")
    let schedulerSource = try routeSource(named: "DashboardReviewsScheduler.swift")

    #expect(supportSource.contains("enum DashboardReviewsRemoteLoader"))
    #expect(supportSource.contains("Task.detached(priority: .userInitiated)"))
    #expect(schedulerSource.contains("DashboardReviewsRemoteLoader.query("))
    #expect(!schedulerSource.contains("client.queryReviews(request: request)"))
    #expect(refreshSource.contains("DashboardReviewsRemoteLoader.refresh("))
  }

  @Test("route source presents native confirmation for risky approve and merge actions")
  func routeSourcePresentsNativeConfirmationForRiskyApproveAndMergeActions() throws {
    let routeViewSource = try routeSource()
    let contentSource = try routeSource(named: "DashboardReviewsRouteView+Content.swift")
    let actionPreviewSource = try routeSource(
      named: "DashboardReviewsRouteView+ActionPreview.swift"
    )
    let attentionSource = try routeSource(named: "DashboardReviewsAttentionActions.swift")
    let actionBarSource = try routeSource(named: "DashboardReviewActionBar.swift")
    let contextMenuSource = try routeSource(
      named: "DashboardReviewsRouteView+ContextMenu.swift"
    )
    let rowSource = try routeSource(named: "DashboardReviewListRow.swift")

    #expect(routeViewSource.contains("@State private var actionState"))
    #expect(routeViewSource.contains(".confirmationDialog("))
    #expect(routeViewSource.contains("confirmReviewAction(confirmation)"))
    #expect(contentSource.contains("onApprove: { requestApproveOrConfirm(items: items) }"))
    #expect(contentSource.contains("onMerge: { requestMergeOrConfirm(items: items) }"))
    #expect(actionPreviewSource.contains("requestReviewAction(.approve, items: items)"))
    #expect(actionPreviewSource.contains("requestReviewAction(.merge, items: items)"))
    #expect(actionPreviewSource.contains("reviewActionPreview("))
    #expect(actionPreviewSource.contains("routePendingActionConfirmation = confirmation"))
    #expect(attentionSource.contains("struct DashboardReviewActionConfirmation"))
    #expect(attentionSource.contains("dashboardReviewActionConfirmation("))
    #expect(attentionSource.contains("func dashboardReviewMergeActionTitle("))
    #expect(actionBarSource.contains("title: dashboardReviewMergeActionTitle(for: items)"))
    #expect(contextMenuSource.contains("Button(dashboardReviewMergeActionTitle(for: items))"))
    #expect(rowSource.contains("dashboardReviewAttentionBadgeKinds(for: item)"))
  }

  @Test("dashboard preview exercises review alert rendering")
  func dashboardPreviewExercisesReviewAlertRendering() throws {
    let source = try previewSource(named: "PreviewDashboardReviewsRouteView.swift")

    #expect(source.contains("> ℹ️ **Note**"))
    #expect(source.contains("This PR body was truncated due to platform limits."))
  }

  @Test("error helper rewrites GitHub 401 messages into actionable copy")
  func errorHelperRewritesGitHubUnauthorizedIntoActionableCopy() {
    let envelope =
      #"{"error":{"code":"WORKFLOW_IO","message":"reviews github "#
      + #"request failed: GitHub API returned 401 Unauthorized: Bad credentials. "#
      + #"Check that the GitHub token is valid"}}"#
    let apiError = HarnessMonitorAPIError.server(code: 400, message: envelope)

    #expect(
      dashboardReviewsErrorMessage(for: apiError)
        == dashboardDepsGitHubAuthFailureMessage
    )
  }

  @Test("error helper detects GitHub 401 messages in non-API errors")
  func errorHelperDetectsGitHubUnauthorizedInTransportLikeErrors() {
    struct LegacyTransportError: LocalizedError {
      var errorDescription: String? {
        "reviews github request failed: GitHub API returned 401 Unauthorized"
      }
    }

    #expect(
      dashboardReviewsErrorMessage(for: LegacyTransportError())
        == dashboardDepsGitHubAuthFailureMessage
    )
  }

  @Test("error helper rewrites DecodingError into version-mismatch copy")
  func errorHelperRewritesDecodingErrorIntoVersionMismatchCopy() {
    let decodingError = DecodingError.valueNotFound(
      String.self,
      DecodingError.Context(codingPath: [], debugDescription: "missing payload")
    )

    #expect(
      dashboardReviewsErrorMessage(for: decodingError)
        == dashboardDepsDecodingFailureMessage
    )
  }

  @Test("error helper passes through unknown localized errors")
  func errorHelperPassesThroughUnknownLocalizedErrors() {
    struct UnknownError: LocalizedError {
      var errorDescription: String? { "everything is on fire" }
    }

    #expect(
      dashboardReviewsErrorMessage(for: UnknownError()) == "everything is on fire"
    )
  }

  @Test("check grouping sorts suites by severity and checks within each suite")
  func checkGroupingSortsSuitesBySeverityAndChecksWithinEachSuite() {
    let passingAnalyze = ReviewCheck(
      name: "Analyze (actions)",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-analyze"
    )
    let failingAnalyze = ReviewCheck(
      name: "Analyze (go)",
      status: .completed,
      conclusion: .failure,
      checkSuiteID: "suite-analyze"
    )
    let pendingTest = ReviewCheck(
      name: "Test / unit",
      status: .queued,
      conclusion: .none
    )
    let passingCodeQL = ReviewCheck(
      name: "CodeQL",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-codeql"
    )

    let groups = dashboardReviewCheckGroups(
      for: [passingCodeQL, pendingTest, passingAnalyze, failingAnalyze]
    )

    #expect(groups.map(\.title) == ["Analyze", "Test", "CodeQL"])
    #expect(groups.first?.checkCountLabel == "2 checks")
    #expect(groups.first?.checks.map(\.name) == ["Analyze (go)", "Analyze (actions)"])
  }

  @Test("rerun check controls explain unavailable state")
  func rerunCheckControlsExplainUnavailableState() {
    let missingSuite = ReviewCheck(
      name: "ci",
      status: .completed,
      conclusion: .failure
    )
    let pending = ReviewCheck(
      name: "ci",
      status: .queued,
      conclusion: .none,
      checkSuiteID: "suite-ci"
    )
    let failed = ReviewCheck(
      name: "ci",
      status: .completed,
      conclusion: .failure,
      checkSuiteID: "suite-ci"
    )

    #expect(
      missingSuite.rerunUnavailableReason
        == "GitHub did not provide a check suite ID for this check."
    )
    #expect(pending.rerunUnavailableReason == "Only completed check runs can be rerun.")
    #expect(failed.rerunUnavailableReason == nil)

    let item = makeReviewItem(checkStatus: .failure, checks: [missingSuite])
    #expect(
      item.rerunChecksUnavailableReason
        == "GitHub did not provide check suite IDs for these checks."
    )
    #expect(!item.canAttemptRerunChecks)
  }

  @Test("activity entries summarize action results per review")
  func activityEntriesSummarizeActionResultsPerReview() {
    let recordedAt = Date(timeIntervalSince1970: 0)
    let response = ReviewsActionResponse(
      summary: "Approved 1 review",
      results: [
        ReviewActionResult(
          repository: "org-a/example",
          number: 42,
          action: .approve,
          outcome: .applied,
          message: "Approved org-a/example#42"
        )
      ]
    )

    let entry = DashboardReviewActivityEntry.success(
      title: "Approving",
      response: response,
      results: response.results,
      recordedAt: recordedAt
    )

    #expect(entry.summary == "Approved 1 review")
    #expect(entry.outcome == .success)
    #expect(entry.messages == ["Approved org-a/example#42"])
    #expect(entry.recordedAt == recordedAt)
  }

  @Test("activity snapshot exposes cache and missing check-link labels")
  func activitySnapshotExposesCacheAndMissingCheckLinkLabels() {
    let snapshot = DashboardReviewActivitySnapshot(
      pullRequestID: "pr-1",
      isRefreshing: true,
      actionTitle: "Approving",
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: true,
      lastAction: nil,
      missingCheckRunURLCount: 2,
      totalCheckCount: 3,
      capabilities: ReviewsCapabilitiesResponse()
    )

    #expect(snapshot.cacheLabel == "Cached data")
    #expect(snapshot.checkLinkLabel == "2/3 check links missing")
  }

  private func routeSource() throws -> String {
    try routeSource(named: "DashboardReviewsRouteView.swift")
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private func previewSource(named fileName: String) throws -> String {
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
        "apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Views/Dashboard/Previews"
      )
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }

  private func makeReviewItem(
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
}
