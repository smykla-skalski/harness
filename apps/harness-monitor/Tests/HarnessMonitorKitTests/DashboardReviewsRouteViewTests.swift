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
    // File-length splits pushed the confirmation routing into the pasted-text
    // sheet companion, the policy run/status helpers into +Actions+Policy, and
    // the confirmation copy into +ConfirmationMessages. Union-read each base
    // file with its companion so every pinned literal resolves.
    let routeViewSource =
      try dashboardReviewsRouteSource()
      + "\n"
      + dashboardReviewsRouteSource(named: "DashboardReviewsRouteView+PastedTextSheet.swift")
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ContentRows.swift")
    let actionsSource =
      try dashboardReviewsRouteSource(named: "DashboardReviewsRouteView+Actions.swift")
      + "\n"
      + dashboardReviewsRouteSource(named: "DashboardReviewsRouteView+Actions+Policy.swift")
    let actionPreviewSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+ActionPreview.swift"
    )
    let attentionSource =
      try dashboardReviewsRouteSource(named: "DashboardReviewsAttentionActions.swift")
      + "\n"
      + dashboardReviewsRouteSource(
        named: "DashboardReviewsAttentionActions+ConfirmationMessages.swift")
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
    // The call now wraps across two lines for the file-length cap, so pin the
    // helper name and its argument label separately.
    #expect(rowSource.contains("dashboardReviewAttentionBadgeKinds("))
    #expect(rowSource.contains("for: item, slaThresholdHours:"))
  }

  @Test("route source persists collapsed secondary queues off the body path")
  func routeSourcePersistsCollapsedSecondaryQueuesOffTheBodyPath() throws {
    let source = try dashboardReviewsRouteSource()
    let stateSource = try dashboardReviewsRouteSource(named: "DashboardReviewsRouteViewState.swift")
    let modesSource = try dashboardReviewsRouteSource(named: "DashboardReviewsListModes.swift")
    let contentSource = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+Content.swift")

    #expect(modesSource.contains("struct DashboardReviewsCollapsedSecondaryQueues"))
    #expect(
      stateSource.contains(
        "var collapsedSecondaryQueues = DashboardReviewsCollapsedSecondaryQueues()"))
    #expect(source.contains("syncCollapsedSecondaryQueuesFromStorage(newValue)"))
    #expect(contentSource.contains("routeCollapsedSecondaryQueues.contains("))
  }
}
