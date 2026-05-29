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
      )
        == .error(
          """
          Harness Monitor is starting up. The local sync engine isn't ready yet. \
          Retry in a moment or check Settings > Diagnostics.
          """
        )
    )
    #expect(
      dashboardReviewsMissingClientState(
        backgroundRefresh: false,
        connectionState: .offline("Daemon stopped")
      )
        == .error(
          """
          Harness Monitor is starting up. The local sync engine isn't ready yet. \
          Retry in a moment or check Settings > Diagnostics.
          """
        )
    )
  }

  @Test("reload task key only changes on the offline -> online edge")
  func reloadTaskKeyOnlyChangesOnTheOfflineToOnlineEdge() {
    let idle = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      isConnected: isReviewsReloadConnected(.idle)
    )
    let connecting = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      isConnected: isReviewsReloadConnected(.connecting)
    )
    let offline = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      isConnected: isReviewsReloadConnected(.offline("Daemon stopped"))
    )
    let online = DashboardReviewsReloadTaskKey(
      preferencesSignature: "",
      isConnected: isReviewsReloadConnected(.online)
    )

    // All non-online states collapse to the same key so flap
    // `offline -> connecting -> online` produces ONE key change, not two.
    #expect(idle == connecting)
    #expect(connecting == offline)
    #expect(offline != online)
  }

  @Test("files mode availability distinguishes settings and selection gaps")
  func filesModeAvailabilityDistinguishesSettingsAndSelectionGaps() {
    #expect(
      dashboardReviewsFilesModeAvailability(
        filesEnabled: false,
        selectionCount: 1,
        hasPrimaryDetailItem: true
      ) == .disabledInPreferences
    )
    #expect(
      dashboardReviewsFilesModeAvailability(
        filesEnabled: true,
        selectionCount: 0,
        hasPrimaryDetailItem: false
      ) == .requiresSelection
    )
    #expect(
      dashboardReviewsFilesModeAvailability(
        filesEnabled: true,
        selectionCount: 2,
        hasPrimaryDetailItem: true
      ) == .requiresSingleSelection
    )
    #expect(
      dashboardReviewsFilesModeAvailability(
        filesEnabled: true,
        selectionCount: 1,
        hasPrimaryDetailItem: true
      ) == .available
    )
    #expect(
      dashboardReviewsFilesModeAvailability(
        filesEnabled: true,
        selectionCount: 0,
        hasPrimaryDetailItem: true
      ) == .available
    )
  }

  @Test("route source reloads from the connection-aware task key")
  func reloadTaskKeyChangesWhenPreferencesSignatureChanges() {
    let first = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=a",
      isConnected: true
    )
    let second = DashboardReviewsReloadTaskKey(
      preferencesSignature: "authors=b",
      isConnected: true
    )

    #expect(first != second)
  }

  @Test("route source caches decoded preferences off the SwiftUI body path")
  func routeSourceCachesDecodedPreferencesOffTheSwiftUIBodyPath() throws {
    let source = try dashboardReviewsRouteSource()
    let supportSource = try dashboardReviewsRouteSource(named: "DashboardReviewsRouteSupport.swift")
    let cacheSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Cache.swift")
    let accessorSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Accessors.swift")
    let stateSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteViewState.swift")
    let schedulerSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Scheduler.swift")

    #expect(supportSource.contains("struct DashboardReviewsResolvedPreferences"))
    #expect(source.contains("@State private var routeState: DashboardReviewsRouteViewState"))
    #expect(stateSource.contains("var resolvedPreferences: DashboardReviewsResolvedPreferences"))
    #expect(
      accessorSource.contains("var routeResolvedPreferences: DashboardReviewsResolvedPreferences"))
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
    let source = try dashboardReviewsRouteSource()

    #expect(source.contains("searchText: searchText"))
    #expect(!source.contains("searchText: \"\""))
  }

  @Test("route source keeps review network decode off the view actor")
  func routeSourceKeepsReviewNetworkDecodeOffTheViewActor() throws {
    let supportSource = try dashboardReviewsRouteSource(named: "DashboardReviewsRouteSupport.swift")
    let refreshSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Refresh.swift")
    let schedulerSource = try dashboardReviewsRouteSource(named: "DashboardReviewsScheduler.swift")

    #expect(supportSource.contains("enum DashboardReviewsRemoteLoader"))
    #expect(supportSource.contains("Task.detached(priority: .userInitiated)"))
    #expect(schedulerSource.contains("DashboardReviewsRemoteLoader.query("))
    #expect(!schedulerSource.contains("client.queryReviews(request: request)"))
    #expect(refreshSource.contains("DashboardReviewsRemoteLoader.refresh("))
  }

  @Test("route source presents native confirmation for risky approve and merge actions")
  func routeSourcePresentsNativeConfirmationForRiskyApproveAndMergeActions() throws {
    let routeViewSource = try dashboardReviewsRouteSource()
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContentRows.swift")
    let actionsSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Actions.swift"
    )
    let actionPreviewSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ActionPreview.swift"
    )
    let attentionSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsAttentionActions.swift")
    let routeStateSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteViewState.swift")
    let actionStateSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteActionState.swift"
    )
    let actionBarSource = try dashboardReviewsRouteSource(named: "DashboardReviewActionBar.swift")
    let contextMenuSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContextMenu.swift"
    )
    let rowSource = try dashboardReviewsRouteSource(named: "DashboardReviewListRow.swift")

    #expect(routeStateSource.contains("var actionState = DashboardReviewsRouteActionState()"))
    #expect(routeViewSource.contains(".confirmationDialog("))
    #expect(routeViewSource.contains("confirmReviewAction(confirmation)"))
    #expect(contentSource.contains("onApprove: { requestApproveOrConfirm(items: items) }"))
    #expect(contentSource.contains("onMerge: { requestMergeOrConfirm(items: items) }"))
    #expect(actionPreviewSource.contains("requestReviewAction(.approve, items: items)"))
    #expect(actionPreviewSource.contains("requestReviewAction(.merge, items: items)"))
    #expect(actionPreviewSource.contains("reviewActionPreview("))
    #expect(actionPreviewSource.contains("reviewAutoPolicyPreview(items: items)"))
    #expect(actionPreviewSource.contains("routePendingActionConfirmation = confirmation"))
    #expect(actionsSource.contains("startReviewsPolicyRun("))
    #expect(actionsSource.contains("reviewsPolicyStatus("))
    #expect(actionsSource.contains("dashboardReviewsAutoPolicyFeedback("))
    #expect(attentionSource.contains("struct DashboardReviewActionConfirmation"))
    #expect(attentionSource.contains("DashboardReviewsAutoPolicyPreview"))
    #expect(attentionSource.contains("dashboardReviewActionConfirmation("))
    #expect(attentionSource.contains("configured Reviews policy workflow"))
    #expect(attentionSource.contains("func dashboardReviewMergeActionTitle("))
    #expect(actionStateSource.contains("policyPreviewByPullRequestID"))
    #expect(actionStateSource.contains("policyStatusByPullRequestID"))
    #expect(actionBarSource.contains("title: dashboardReviewMergeActionTitle(for: items)"))
    #expect(contextMenuSource.contains("Button(dashboardReviewMergeActionTitle(for: items))"))
    #expect(rowSource.contains("dashboardReviewAttentionBadgeKinds(for: item, slaThresholdHours:"))
  }

  @Test("single-PR auto feedback explains approval-only outcomes")
  func singlePRAutoFeedbackExplainsApprovalOnlyOutcomes() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let response = ReviewsActionResponse(
      summary: "Auto mode finished: 1 applied, 0 skipped, 0 failed",
      results: [
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoApprove,
          outcome: .applied
        )
      ]
    )

    let feedback = dashboardReviewsActionFeedback(
      title: "Auto",
      items: [item],
      response: response
    )

    #expect(feedback.severity == .success)
    #expect(
      feedback.message
        == "Approved org-a/example#42. GitHub still requires review before merge."
    )
  }

  @Test("single-PR auto feedback surfaces merge failures as failures")
  func singlePRAutoFeedbackSurfacesMergeFailures() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let response = ReviewsActionResponse(
      summary: "Auto mode finished: 1 applied, 0 skipped, 1 failed",
      results: [
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoApprove,
          outcome: .applied
        ),
        ReviewActionResult(
          repository: item.repository,
          number: item.number,
          action: .autoMerge,
          outcome: .failed,
          message: "GitHub still requires review before merge."
        ),
      ]
    )

    let feedback = dashboardReviewsActionFeedback(
      title: "Auto",
      items: [item],
      response: response
    )

    #expect(feedback.severity == .failure)
    #expect(
      feedback.message
        == "Approved org-a/example#42, but merge failed: GitHub still requires review before merge"
    )
  }

  @Test("single-PR auto policy feedback explains waiting runs")
  func singlePRAutoPolicyFeedbackExplainsWaitingRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired, checkStatus: .pending)
    let outcome = DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
          ReviewsPolicyPreviewStep(
            stepType: .wait,
            waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
          ),
        ]
      ),
      run: ReviewsPolicyRunResponse(
        runID: "run-1",
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: .waiting,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:01Z",
        waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed"),
        steps: [
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.approve",
            recordedAt: "2026-05-29T12:00:00Z"
          ),
          ReviewsPolicyRunStep(
            stepType: .wait,
            waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed"),
            recordedAt: "2026-05-29T12:00:01Z"
          ),
        ]
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )

    let feedback = dashboardReviewsAutoPolicyFeedback(items: [item], outcomes: [outcome])

    #expect(feedback.severity == .warning)
    #expect(
      feedback.message
        == "Auto policy started for org-a/example#42: approved; waiting for required checks to pass."
    )
  }

  @Test("single-PR auto policy feedback explains completed runs")
  func singlePRAutoPolicyFeedbackExplainsCompletedRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let outcome = DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
          ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.merge"),
        ]
      ),
      run: ReviewsPolicyRunResponse(
        runID: "run-1",
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: .completed,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:03Z",
        completedAt: "2026-05-29T12:00:03Z",
        steps: [
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.approve",
            recordedAt: "2026-05-29T12:00:00Z"
          ),
          ReviewsPolicyRunStep(
            stepType: .action,
            actionKey: "reviews.merge",
            recordedAt: "2026-05-29T12:00:03Z"
          ),
        ]
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )

    let feedback = dashboardReviewsAutoPolicyFeedback(items: [item], outcomes: [outcome])

    #expect(feedback.severity == .success)
    #expect(
      feedback.message
        == "Auto policy completed for org-a/example#42: approved and merged."
    )
  }

  @Test("multi-PR auto policy aggregation never reports green when a run is unfinished")
  func multiPRAutoPolicyAggregationNeverReportsGreenForUnfinishedRuns() {
    let item = reviewItem(reviewStatus: .reviewRequired)
    let outcomes = [
      autoPolicyOutcome(item: item, runID: "run-1", status: .completed),
      autoPolicyOutcome(item: item, runID: "run-2", status: .waiting),
      autoPolicyOutcome(
        item: item,
        runID: "run-3",
        status: .failed,
        errorMessage: "merge blocked by branch protection"
      ),
      autoPolicyOutcome(item: item, runID: "run-4", status: .unknown("event")),
    ]

    let feedback = dashboardReviewsAutoPolicyFeedback(
      items: [item, item, item, item],
      outcomes: outcomes
    )

    #expect(feedback.severity != .success)
    #expect(feedback.severity == .failure)
    #expect(feedback.message.contains("1 completed"))
    #expect(feedback.message.contains("1 waiting"))
    #expect(feedback.message.contains("2 failed"))
    #expect(feedback.message.contains("merge blocked by branch protection"))
  }

  private func autoPolicyOutcome(
    item: ReviewItem,
    runID: String,
    status: ReviewsPolicyRunStatus,
    errorMessage: String? = nil
  ) -> DashboardReviewsAutoPolicyOutcome {
    DashboardReviewsAutoPolicyOutcome(
      item: item,
      preview: ReviewsPolicyPreviewResponse(
        eligible: true,
        steps: [ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve")]
      ),
      run: ReviewsPolicyRunResponse(
        runID: runID,
        subject: item.target.reviewsPolicySubject,
        trigger: .manual,
        status: status,
        startedAt: "2026-05-29T12:00:00Z",
        updatedAt: "2026-05-29T12:00:01Z",
        errorMessage: status == .failed ? errorMessage : nil
      ),
      status: nil,
      skippedReason: nil,
      errorMessage: nil
    )
  }

  @Test("auto policy confirmation describes planned workflow steps")
  func autoPolicyConfirmationDescribesPlannedWorkflowSteps() {
    let item = reviewItem(reviewStatus: .reviewRequired, checkStatus: .pending)
    let preview = DashboardReviewsAutoPolicyPreview(
      targets: [
        DashboardReviewsAutoPolicyPreviewTarget(
          item: item,
          preview: ReviewsPolicyPreviewResponse(
            eligible: true,
            steps: [
              ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.approve"),
              ReviewsPolicyPreviewStep(
                stepType: .wait,
                waitingOn: ReviewsPolicyWait(eventKey: "reviews.checks_passed")
              ),
              ReviewsPolicyPreviewStep(stepType: .action, actionKey: "reviews.merge"),
            ],
            warnings: ["Merge will wait for required checks to pass."]
          )
        )
      ]
    )

    let confirmation = dashboardReviewActionConfirmation(
      for: .auto,
      items: [item],
      preview: preview,
      mergeMethod: .squash
    )

    #expect(confirmation?.confirmButtonTitle == "Start Auto Policy on 1 Pull Request")
    #expect(
      confirmation?.message.contains("configured Reviews policy workflow") == true
    )
    #expect(confirmation?.message.contains("Planned steps:") == true)
    #expect(confirmation?.message.contains("1. Approve the pull request") == true)
    #expect(confirmation?.message.contains("2. Wait for required checks to pass") == true)
    #expect(
      confirmation?.message.contains("3. Merge the pull request using Squash") == true
    )
  }

  @Test("route source resolves primary selection via the delta-aware helper")
  func routeSourceResolvesPrimarySelectionViaDeltaAwareHelper() throws {
    let source = try dashboardReviewsRouteSource()
    let selectionSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Selection.swift")
    let routeStateSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteViewState.swift")

    // The buggy lexical-min assignment must be gone from the onChange body.
    #expect(
      !source.contains(
        "persistedPrimarySelectionID = newValue.min() ?? persistedPrimarySelectionID"
      )
    )
    // The route must delegate to the pure resolver and track the last
    // click so future passes can disambiguate select-all vs single-click.
    #expect(source.contains("DashboardReviewsPrimarySelectionResolver.resolve("))
    #expect(source.contains("routeState.lastPrimaryClickedID = added.first"))
    #expect(routeStateSource.contains("var lastPrimaryClickedID: String?"))
    #expect(selectionSource.contains("enum DashboardReviewsPrimarySelectionResolver"))
    #expect(selectionSource.contains("static func resolve("))
  }

  @Test("route source replays pending selection when items finally load")
  func routeSourceReplaysPendingSelectionWhenItemsFinallyLoad() throws {
    let source = try dashboardReviewsRouteSource()

    // The original .task(id: openAnythingReviews.selectionRequest) trigger
    // must still be there - it covers the case where items are already loaded.
    #expect(source.contains(".task(id: openAnythingReviews.selectionRequest)"))
    // The items-arrival onChange handler must also call the apply helper so
    // a request that fired before items loaded gets a second chance.
    #expect(
      source.contains(
        ".onChange(of: routeResponse.items, initial: true) { _, items in\n"
          + "        openAnythingReviews.replaceLoadedItems(items)\n"
      )
    )
    #expect(source.contains("applyPendingReviewSelectionIfNeeded()"))
  }

  @Test("pending review selection request stops replaying once finished")
  @MainActor
  func pendingReviewSelectionRequestStopsReplayingOnceFinished() {
    // Drive the registry directly to confirm the idempotency contract the
    // route helper relies on: requesting selection sets a request, finishing
    // clears it, and a redundant finish is a no-op.
    let registry = OpenAnythingDashboardReviewRegistry()
    registry.requestSelection(pullRequestID: "PR_kwAOXXX")
    let firstRequest = registry.selectionRequest
    #expect(firstRequest?.pullRequestID == "PR_kwAOXXX")

    registry.finishSelection(requestID: firstRequest?.requestID ?? -1)
    #expect(registry.selectionRequest == nil)

    // A second call after the request has been cleared must be a no-op.
    registry.finishSelection(requestID: firstRequest?.requestID ?? -1)
    #expect(registry.selectionRequest == nil)
  }

  @Test("dashboard preview exercises review alert rendering")
  func dashboardPreviewExercisesReviewAlertRendering() throws {
    let source = try dashboardReviewsRoutePreviewSource(
      named: "PreviewDashboardReviewsRouteView.swift")

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
        == dashboardReviewsGitHubAuthFailureMessage
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
        == dashboardReviewsGitHubAuthFailureMessage
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
        == dashboardReviewsDecodingFailureMessage
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

    let item = dashboardReviewsTestReviewItem(checkStatus: .failure, checks: [missingSuite])
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

  @Test("history selection normalizes empty and multi-selection Files states")
  func historySelectionNormalizesInvalidFilesStates() {
    let empty = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: [],
      primaryPullRequestID: "PR-1",
      detailMode: .files
    )
    #expect(empty.selectedPullRequestIDs.isEmpty)
    #expect(empty.primaryPullRequestID.isEmpty)
    #expect(empty.detailMode == .overview)

    let multi = DashboardReviewsHistorySelection(
      selectedPullRequestIDs: ["PR-2", "PR-1", "PR-2"],
      primaryPullRequestID: "missing",
      detailMode: .files
    )
    #expect(multi.selectedPullRequestIDs == ["PR-1", "PR-2"])
    #expect(multi.primaryPullRequestID == "PR-1")
    #expect(multi.detailMode == .overview)
  }
}

private func reviewItem(
  reviewStatus: ReviewReviewStatus,
  checkStatus: ReviewCheckStatus = .success
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
    reviewStatus: reviewStatus,
    checkStatus: checkStatus,
    policyBlocked: false,
    isDraft: false,
    headSha: "abc123",
    additions: 10,
    deletions: 4,
    createdAt: "2026-05-20T10:00:00Z",
    updatedAt: "2026-05-20T11:00:00Z",
    viewerCanUpdate: true
  )
}
