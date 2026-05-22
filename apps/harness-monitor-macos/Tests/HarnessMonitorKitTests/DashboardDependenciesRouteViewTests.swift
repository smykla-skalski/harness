import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependencies route view")
struct DashboardDependenciesRouteViewTests {
  @Test("missing-client state keeps the route loading while the daemon connects")
  func missingClientStateKeepsLoadingWhileConnecting() {
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .connecting
      ) == .loading
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: true,
        connectionState: .connecting
      ) == .ignore
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .idle
      ) == .error("The dependencies route needs a daemon client")
    )
    #expect(
      dashboardDependenciesMissingClientState(
        backgroundRefresh: false,
        connectionState: .offline("Daemon stopped")
      ) == .error("The dependencies route needs a daemon client")
    )
  }

  @Test("reload task key changes when connection state changes")
  func reloadTaskKeyChangesWhenConnectionStateChanges() {
    let idle = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .idle
    )
    let connecting = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .connecting
    )
    let online = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "",
      connectionState: .online
    )

    #expect(idle != connecting)
    #expect(connecting != online)
  }

  @Test("route source reloads from the connection-aware task key")
  func reloadTaskKeyChangesWhenPreferencesSignatureChanges() {
    let first = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "authors=a",
      connectionState: .online
    )
    let second = DashboardDependenciesReloadTaskKey(
      preferencesSignature: "authors=b",
      connectionState: .online
    )

    #expect(first != second)
  }

  @Test("route source caches decoded preferences off the SwiftUI body path")
  func routeSourceCachesDecodedPreferencesOffTheSwiftUIBodyPath() throws {
    let source = try routeSource()
    let supportSource = try routeSource(named: "DashboardDependenciesRouteSupport.swift")
    let cacheSource = try routeSource(named: "DashboardDependenciesRouteView+Cache.swift")
    let schedulerSource = try routeSource(named: "DashboardDependenciesRouteView+Scheduler.swift")

    #expect(supportSource.contains("struct DashboardDependenciesResolvedPreferences"))
    #expect(source.contains("@State private var resolvedPreferences"))
    #expect(
      source.contains("var routeResolvedPreferences: DashboardDependenciesResolvedPreferences"))
    #expect(source.contains(".onChange(of: storedPreferences, initial: true)"))
    #expect(source.contains("syncPreferencesFromStorage(newValue)"))
    #expect(
      !source.contains("get { DashboardDependenciesPreferences.decode(from: storedPreferences) }"))
    #expect(
      !source.contains(
        "var normalizedPreferences: DashboardDependenciesPreferences {\n    preferences.normalized()"
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

  @Test("route source keeps dependency network decode off the view actor")
  func routeSourceKeepsDependencyNetworkDecodeOffTheViewActor() throws {
    let supportSource = try routeSource(named: "DashboardDependenciesRouteSupport.swift")
    let refreshSource = try routeSource(named: "DashboardDependenciesRouteView+Refresh.swift")
    let schedulerSource = try routeSource(named: "DashboardDependenciesScheduler.swift")

    #expect(supportSource.contains("enum DashboardDependenciesRemoteLoader"))
    #expect(supportSource.contains("Task.detached(priority: .userInitiated)"))
    #expect(schedulerSource.contains("DashboardDependenciesRemoteLoader.query("))
    #expect(!schedulerSource.contains("client.queryDependencyUpdates(request: request)"))
    #expect(refreshSource.contains("DashboardDependenciesRemoteLoader.refresh("))
  }

  @Test("route source presents native confirmation for risky approve and merge actions")
  func routeSourcePresentsNativeConfirmationForRiskyApproveAndMergeActions() throws {
    let routeViewSource = try routeSource()
    let contentSource = try routeSource(named: "DashboardDependenciesRouteView+Content.swift")
    let actionsSource = try routeSource(named: "DashboardDependenciesRouteView+Actions.swift")
    let attentionSource = try routeSource(named: "DashboardDependenciesAttentionActions.swift")

    #expect(routeViewSource.contains("@State private var pendingActionConfirmation"))
    #expect(routeViewSource.contains(".confirmationDialog("))
    #expect(routeViewSource.contains("confirmDependencyAction(confirmation)"))
    #expect(contentSource.contains("onApprove: { requestApproveOrConfirm(items: items) }"))
    #expect(contentSource.contains("onMerge: { requestMergeOrConfirm(items: items) }"))
    #expect(actionsSource.contains("requestDependencyActionConfirmation(.approve, items: items)"))
    #expect(actionsSource.contains("requestDependencyActionConfirmation(.merge, items: items)"))
    #expect(attentionSource.contains("struct DashboardDependencyActionConfirmation"))
    #expect(attentionSource.contains("dashboardDependencyActionConfirmation("))
  }

  @Test("dashboard preview exercises dependency alert rendering")
  func dashboardPreviewExercisesDependencyAlertRendering() throws {
    let source = try previewSource(named: "PreviewDashboardDependenciesRouteView.swift")

    #expect(source.contains("> ℹ️ **Note**"))
    #expect(source.contains("This PR body was truncated due to platform limits."))
  }

  @Test("error helper rewrites GitHub 401 messages into actionable copy")
  func errorHelperRewritesGitHubUnauthorizedIntoActionableCopy() {
    let envelope =
      #"{"error":{"code":"WORKFLOW_IO","message":"dependency-updates github "#
      + #"request failed: GitHub API returned 401 Unauthorized: Bad credentials. "#
      + #"Check that the GitHub token is valid"}}"#
    let apiError = HarnessMonitorAPIError.server(code: 400, message: envelope)

    #expect(
      dashboardDependenciesErrorMessage(for: apiError)
        == dashboardDepsGitHubAuthFailureMessage
    )
  }

  @Test("error helper detects GitHub 401 messages in non-API errors")
  func errorHelperDetectsGitHubUnauthorizedInTransportLikeErrors() {
    struct LegacyTransportError: LocalizedError {
      var errorDescription: String? {
        "dependency-updates github request failed: GitHub API returned 401 Unauthorized"
      }
    }

    #expect(
      dashboardDependenciesErrorMessage(for: LegacyTransportError())
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
      dashboardDependenciesErrorMessage(for: decodingError)
        == dashboardDepsDecodingFailureMessage
    )
  }

  @Test("error helper passes through unknown localized errors")
  func errorHelperPassesThroughUnknownLocalizedErrors() {
    struct UnknownError: LocalizedError {
      var errorDescription: String? { "everything is on fire" }
    }

    #expect(
      dashboardDependenciesErrorMessage(for: UnknownError()) == "everything is on fire"
    )
  }

  @Test("check grouping sorts suites by severity and checks within each suite")
  func checkGroupingSortsSuitesBySeverityAndChecksWithinEachSuite() {
    let passingAnalyze = DependencyUpdateCheck(
      name: "Analyze (actions)",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-analyze"
    )
    let failingAnalyze = DependencyUpdateCheck(
      name: "Analyze (go)",
      status: .completed,
      conclusion: .failure,
      checkSuiteID: "suite-analyze"
    )
    let pendingTest = DependencyUpdateCheck(
      name: "Test / unit",
      status: .queued,
      conclusion: .none
    )
    let passingCodeQL = DependencyUpdateCheck(
      name: "CodeQL",
      status: .completed,
      conclusion: .success,
      checkSuiteID: "suite-codeql"
    )

    let groups = dashboardDependencyCheckGroups(
      for: [passingCodeQL, pendingTest, passingAnalyze, failingAnalyze]
    )

    #expect(groups.map(\.title) == ["Analyze", "Test", "CodeQL"])
    #expect(groups.first?.checkCountLabel == "2 checks")
    #expect(groups.first?.checks.map(\.name) == ["Analyze (go)", "Analyze (actions)"])
  }

  @Test("rerun check controls explain unavailable state")
  func rerunCheckControlsExplainUnavailableState() {
    let missingSuite = DependencyUpdateCheck(
      name: "ci",
      status: .completed,
      conclusion: .failure
    )
    let pending = DependencyUpdateCheck(
      name: "ci",
      status: .queued,
      conclusion: .none,
      checkSuiteID: "suite-ci"
    )
    let failed = DependencyUpdateCheck(
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

    let item = makeDependencyItem(checkStatus: .failure, checks: [missingSuite])
    #expect(
      item.rerunChecksUnavailableReason
        == "GitHub did not provide check suite IDs for these checks."
    )
    #expect(!item.canAttemptRerunChecks)
  }

  @Test("activity entries summarize action results per dependency")
  func activityEntriesSummarizeActionResultsPerDependency() {
    let recordedAt = Date(timeIntervalSince1970: 0)
    let response = DependencyUpdatesActionResponse(
      summary: "Approved 1 dependency update",
      results: [
        DependencyUpdateActionResult(
          repository: "org-a/example",
          number: 42,
          action: .approve,
          outcome: .applied,
          message: "Approved org-a/example#42"
        )
      ]
    )

    let entry = DashboardDependencyActivityEntry.success(
      title: "Approving",
      response: response,
      results: response.results,
      recordedAt: recordedAt
    )

    #expect(entry.summary == "Approved 1 dependency update")
    #expect(entry.outcome == .success)
    #expect(entry.messages == ["Approved org-a/example#42"])
    #expect(entry.recordedAt == recordedAt)
  }

  @Test("activity snapshot exposes cache and missing check-link labels")
  func activitySnapshotExposesCacheAndMissingCheckLinkLabels() {
    let snapshot = DashboardDependencyActivitySnapshot(
      pullRequestID: "pr-1",
      isRefreshing: true,
      actionTitle: "Approving",
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: true,
      lastAction: nil,
      missingCheckRunURLCount: 2,
      totalCheckCount: 3
    )

    #expect(snapshot.cacheLabel == "Cached data")
    #expect(snapshot.checkLinkLabel == "2/3 check links missing")
  }

  private func routeSource() throws -> String {
    try routeSource(named: "DashboardDependenciesRouteView.swift")
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

  private func makeDependencyItem(
    checkStatus: DependencyUpdateCheckStatus,
    checks: [DependencyUpdateCheck]
  ) -> DependencyUpdateItem {
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
