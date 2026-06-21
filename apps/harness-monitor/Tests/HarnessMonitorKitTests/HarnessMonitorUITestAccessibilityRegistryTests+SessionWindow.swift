import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Dashboard and session window identifiers match UI-test mirror")
  func dashboardAndSessionWindowIdentifiersMirror() {
    expectDashboardIdentifiersMirrorRegistry()
    expectReviewsIdentifiersMirrorRegistry()
    expectSessionWindowIdentifiersMirrorRegistry()
  }

  private func expectDashboardIdentifiersMirrorRegistry() {
    #expect(HarnessMonitorAccessibility.dashboardWindowRoot == "harness.dashboard.window")
    #expect(HarnessMonitorAccessibility.dashboardSidebar == "harness.dashboard.sidebar")
    #expect(HarnessMonitorAccessibility.dashboardScrollView == "harness.dashboard.scroll")
    #expect(
      HarnessMonitorAccessibility.dashboardNewSessionButton == "harness.dashboard.new-session")
    #expect(
      HarnessMonitorAccessibility.dashboardOpenFolderButton == "harness.dashboard.open-folder")
    #expect(
      HarnessMonitorAccessibility.dashboardWindowRoute("taskBoard")
        == "harness.dashboard.route.taskboard"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardWindowRoute("dependencies")
        == "harness.dashboard.route.reviews"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardAuditRoot
        == "harness.dashboard.audit"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardAuditDetailDivider
        == "harness.dashboard.audit.content-detail-divider"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDiagnosticsRoot
        == "harness.dashboard.diagnostics"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingRoot
        == "harness.dashboard.debugging"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRDropZone
        == "harness.dashboard.debugging.ocr.drop-zone"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRChooseButton
        == "harness.dashboard.debugging.ocr.choose"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRClipboardButton
        == "harness.dashboard.debugging.ocr.clipboard"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRClearButton
        == "harness.dashboard.debugging.ocr.clear"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRShotWatcher
        == "harness.dashboard.debugging.ocr.screenshot-watcher"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRShotChooseButton
        == "harness.dashboard.debugging.ocr.screenshot.choose"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRShotStopButton
        == "harness.dashboard.debugging.ocr.screenshot.stop"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRShotStatus
        == "harness.dashboard.debugging.ocr.screenshot.status"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRRecentSection
        == "harness.dashboard.debugging.ocr.recent"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRResultList
        == "harness.dashboard.debugging.ocr.results"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRResultPreviewButton
        == "harness.dashboard.debugging.ocr.result.preview"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDebuggingOCRPreviewText
        == "harness.dashboard.debugging.ocr.preview.text"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardAuditScrollView
        == "harness.dashboard.audit.scroll"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardAuditRow("toast-success")
        == "harness.dashboard.audit.row.toast-success"
    )
  }

  private func expectReviewsIdentifiersMirrorRegistry() {
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsRoot
        == "harness.dashboard.reviews"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsProvenance
        == "harness.dashboard.reviews.provenance"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsList
        == "harness.dashboard.reviews.list"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsDetail
        == "harness.dashboard.reviews.detail"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsDetailDivider
        == "harness.dashboard.reviews.content-detail-divider"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsRefreshButton
        == "harness.dashboard.reviews.refresh"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsInfoButton
        == "harness.dashboard.reviews.toolbar-info"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsFixCIButton
        == "harness.dashboard.reviews.fix-ci"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsMoreButton
        == "harness.dashboard.reviews.more"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardReviewsSelectionStatus
        == "harness.dashboard.reviews.selection"
    )
  }

  private func expectSessionWindowIdentifiersMirrorRegistry() {
    #expect(HarnessMonitorAccessibility.sessionWindowShell == "harness.session.window")
    #expect(
      HarnessMonitorAccessibility.sessionWindowSidebar
        == "harness.session.window.sidebar"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowStatusSurface
        == "harness.session.window.status"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed
        == "harness.session.window.toolbar.separator-suppressed"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowFocusModeButton
        == "harness.session.window.toolbar.focus-mode"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowCreateProviderPane
        == "harness.session.window.create.provider-pane"
    )
    #expect(
      HarnessMonitorAccessibility.sessionNavigateBackButton
        == "harness.session.window.toolbar.navigate-back"
    )
    #expect(
      HarnessMonitorAccessibility.sessionNavigateForwardButton
        == "harness.session.window.toolbar.navigate-forward"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowInspector
        == "harness.session.window.inspector"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowInspectorCloseButton
        == "harness.session.window.inspector.close"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowRoute(.decisions)
        == "harness.session.window.route.decisions"
    )
    #expect(
      HarnessMonitorAccessibility.settingsLaunchBehaviorPicker
        == "harness.settings.launch-behavior"
    )
    #expect(
      HarnessMonitorAccessibility.newCodexAgentSheet
        == "harness.new-codex-agent.sheet"
    )
  }

  @Test("Dashboard and session window identifiers are attached by production views")
  func dashboardAndSessionWindowAccessibilityIdentifiersAreAttachedByProductionViews() throws {
    try expectDashboardIdentifierUsage()
    try expectReviewsIdentifierUsage()
    try expectSessionWindowIdentifierUsage()
  }

  private func expectDashboardIdentifierUsage() throws {
    let dashboardRoot = try sourceFile(named: "DashboardWindowView.swift")
    let dashboardView = try sourceFile(named: "DashboardWindowSupport.swift")
    let dashboardRouteContent = try sourceFile(named: "DashboardRouteContent.swift")
    let dashboardSidebarSessionsView = try sourceFile(
      named: "DashboardSidebarRecentSessionsSection.swift"
    )
    let auditView = try dashboardAuditSource()
    let diagnosticsView = try sourceFile(named: "DashboardDiagnosticsRouteView.swift")
    let debuggingView = try sourceFile(named: "DashboardDebuggingRouteView.swift")
    let debuggingScreenshotsView = try sourceFile(named: "DashboardDebuggingOCRScreenshots.swift")
    let debuggingResultCard = try sourceFile(named: "DashboardDebuggingOCRResultCard.swift")
    let debuggingPreview = try sourceFile(named: "DashboardDebuggingOCRPreview.swift")
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")

    #expect(
      dashboardRoot.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.dashboardWindowRoot)"
      )
    )
    #expect(dashboardView.contains("HarnessMonitorAccessibility.dashboardSidebar"))
    #expect(
      dashboardView.contains("HarnessMonitorAccessibility.dashboardWindowRoute(route.rawValue)"))
    #expect(
      dashboardSidebarSessionsView.contains(
        "HarnessMonitorAccessibility.sessionRow(session.sessionId)"
      )
    )
    try expectDashboardAuditIdentifierUsage(in: auditView)
    #expect(diagnosticsView.contains("HarnessMonitorAccessibility.dashboardDiagnosticsRoot"))
    expectDashboardDebuggingIdentifierUsage(
      debuggingView: debuggingView,
      screenshotsView: debuggingScreenshotsView,
      resultCardView: debuggingResultCard,
      previewView: debuggingPreview
    )
    expectDashboardSidebarIdentifierUsage(
      dashboardView: dashboardView,
      sidebarSessionsView: dashboardSidebarSessionsView
    )
    #expect(dashboardRouteContent.contains("HarnessMonitorAccessibility.dashboardScrollView"))
    #expect(
      auditView.contains("HarnessMonitorAccessibility.dashboardAuditScrollView"))
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardNewSessionButton"))
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardOpenFolderButton"))
    #expect(dashboardRouteContent.contains("DashboardAuditRouteView("))
    #expect(dashboardRouteContent.contains("DashboardReviewsRouteView("))
    #expect(dashboardToolbar.contains("SleepPreventionToolbarButton("))
  }

  private func expectDashboardAuditIdentifierUsage(in auditView: String) throws {
    #expect(auditView.contains("HarnessMonitorAccessibility.dashboardAuditRoot"))
    #expect(auditView.contains("HarnessMonitorAccessibility.dashboardAuditDetailDivider"))
    #expect(auditView.contains("SessionContentDetailSplitView("))
    #expect(auditView.contains("DashboardAuditDayDivider(label: dayDividerLabel)"))
    #expect(!auditView.contains("SessionTimelineDayDivider(label: dayDividerLabel)"))
    #expect(auditView.contains("let currentDay = timelineDayStart(for: .now"))
    #expect(auditView.contains("previousDay == nil ? day != currentDay : previousDay != day"))
    #expect(auditView.contains("ProviderBrandSymbolView("))
    #expect(auditView.contains("symbol: .github"))
    #expect(auditView.contains("row.event.showsGitHubEdgeMark"))
    #expect(auditView.contains("event.outcomeTint"))
    #expect(auditView.contains("private var titleRow: some View"))
    #expect(auditView.contains("private var subtitleRow: some View"))
    #expect(auditView.contains("static let pageSize = 40"))
    let datePickerRange = try #require(
      auditView.range(of: "Picker(\"Date\", selection: $filters.datePreset)")
    )
    let actionKeyRange = try #require(
      auditView.range(of: "TextField(\"Action key\", text: $filters.actionKey)")
    )
    let datePickerSource = auditView[datePickerRange.lowerBound..<actionKeyRange.lowerBound]
    #expect(datePickerSource.contains(".fixedSize(horizontal: true, vertical: false)"))
    #expect(!datePickerSource.contains(".frame(width:"))
    #expect(!datePickerSource.contains("datePickerWidth"))
    #expect(auditView.contains("dashboardUI.auditHasOlder"))
    #expect(auditView.contains("DashboardAuditLoadMoreButton(action: loadMoreEvents)"))
    #expect(!auditView.contains("dashboardUI.auditEvents.isEmpty"))
    #expect(!auditView.contains("notificationHistory.map(HarnessMonitorAuditEvent.notification)"))
    #expect(auditView.contains(".animation(.snappy(duration: 0.18), value: rows.map(\\.id))"))
    let badgeRange = try #require(
      auditView.range(of: "DashboardAuditOutcomeBadge(event: row.event)")
    )
    let githubConditionRange = try #require(
      auditView.range(of: "if row.event.showsGitHubEdgeMark {")
    )
    #expect(githubConditionRange.lowerBound < badgeRange.lowerBound)
    #expect(!auditView.contains("githubMarkColumnWidth"))
    #expect(!auditView.contains("timeColumnWidth"))
    #expect(
      auditView.contains(
        "DashboardAuditJSONPayloadBlock(title: \"Payload\", payload: payload)"
      )
    )
    #expect(auditView.contains("HarnessMonitorJSONCodeBlock(rawJSON: payload)"))
    #expect(!auditView.contains("DashboardAuditTextBlock(title: \"Payload\", text: payload)"))
    #expect(auditView.contains(".harnessFocusedSceneValue("))
    #expect(auditView.contains("\\.dashboardAuditCopyCommand"))
    #expect(!auditView.contains(".focusedSceneValue(\\.dashboardAuditCopyCommand"))
    #expect(auditView.contains("DashboardAuditCopyFocus("))
    #expect(auditView.contains("@FocusState private var focusedFilterField"))
    #expect(auditView.contains("focusedField: $focusedFilterField"))
    #expect(auditView.contains("focusedFilterField == nil"))
    #expect(auditView.contains(".focused(focusedField, equals: .actionKey)"))
    #expect(auditView.contains(".focused(focusedField, equals: .subject)"))
    #expect(auditView.contains(".focused(focusedField, equals: .searchText)"))
    #expect(auditView.contains("selectedEvent?.clipboardJSONString"))
    #expect(auditView.contains(".contextMenu {"))
    #expect(auditView.contains("Button(\"Copy Event\")"))
    #expect(auditView.contains("copyEvent(row.event)"))
    let commandsSource = try sourceFile(named: "HarnessMonitorAppCommands.swift")
    #expect(commandsSource.contains("@FocusedValue(\\.dashboardAuditCopyCommand)"))
    #expect(commandsSource.contains("Copy Audit Event"))
    let auditCopyCommandsRange = try #require(
      commandsSource.range(of: "private var dashboardAuditCopyCommands: some Commands")
    )
    let viewCommandsRange = try #require(
      commandsSource.range(of: "private var viewCommands: some Commands")
    )
    let auditCopyCommandsSource =
      commandsSource[auditCopyCommandsRange.lowerBound..<viewCommandsRange.lowerBound]
    #expect(auditCopyCommandsSource.contains("CommandGroup(replacing: .pasteboard)"))
    #expect(!auditCopyCommandsSource.contains("CommandGroup(after: .pasteboard)"))
    #expect(auditCopyCommandsSource.contains(".keyboardShortcut(\"c\", modifiers: .command)"))
    #expect(auditCopyCommandsSource.contains("dashboardAuditCopyFocus.canCopy"))
    #expect(auditCopyCommandsSource.contains("dashboardAuditCopyFocus.copy()"))
  }

  private func dashboardAuditSource() throws -> String {
    try [
      "DashboardAuditRouteView.swift",
      "DashboardAuditRouteView+Timeline.swift",
      "DashboardAuditRouteView+DisplaySupport.swift",
      "DashboardAuditRouteView+Detail.swift",
    ]
    .map { try sourceFile(named: $0) }
    .joined(separator: "\n")
  }

  private func expectDashboardDebuggingIdentifierUsage(
    debuggingView: String,
    screenshotsView: String,
    resultCardView: String,
    previewView: String
  ) {
    #expect(debuggingView.contains("HarnessMonitorAccessibility.dashboardDebuggingRoot"))
    #expect(
      screenshotsView.contains(
        "HarnessMonitorAccessibility.dashboardDebuggingOCRShotWatcher"
      )
    )
    #expect(
      screenshotsView.contains(
        "HarnessMonitorAccessibility.dashboardDebuggingOCRShotStatus"
      )
    )
    #expect(
      resultCardView.contains(
        "HarnessMonitorAccessibility.dashboardDebuggingOCRResultPreviewButton"
      )
    )
    #expect(
      previewView.contains("HarnessMonitorAccessibility.dashboardDebuggingOCRPreviewText")
    )
  }

  private func expectDashboardSidebarIdentifierUsage(
    dashboardView: String,
    sidebarSessionsView: String
  ) {
    #expect(dashboardView.contains("HarnessMonitorSidebar("))
    #expect(dashboardView.contains("List(selection: dashboardSelectionBinding)"))
    #expect(dashboardView.contains("SessionSidebarRow("))
    #expect(!dashboardView.contains("Section(\"Routes\")"))
    #expect(dashboardView.contains("DashboardSidebarRecentSessionsSection("))
    #expect(sidebarSessionsView.contains("Section(\"Recent sessions\")"))
    #expect(sidebarSessionsView.contains("SessionSidebarRow("))
    #expect(sidebarSessionsView.contains("subtitle: subtitle"))
    #expect(sidebarSessionsView.contains("projectAndWorktreeDisplayLabel(separator: \"·\")"))
    #expect(dashboardView.contains(".harnessMonitorSidebarListChrome("))
  }

  private func expectReviewsIdentifierUsage() throws {
    let reviewsView = try sourceFile(named: "DashboardReviewsRouteView.swift")
    let contentView = try sourceFile(named: "DashboardReviewsRouteView+Content.swift")
    let controlStripView = try sourceFile(named: "DashboardReviewsControlStrip.swift")
    let actionBarView = try sourceFile(named: "DashboardReviewActionBar.swift")
    let provenanceView = try sourceFile(named: "DashboardReviewsProvenance.swift")

    #expect(
      reviewsView.contains("HarnessMonitorAccessibility.dashboardReviewsRoot")
    )
    #expect(
      provenanceView.contains("HarnessMonitorAccessibility.dashboardReviewsProvenance")
    )
    #expect(
      contentView.contains("HarnessMonitorAccessibility.dashboardReviewsList")
    )
    #expect(
      contentView.contains("HarnessMonitorAccessibility.dashboardReviewsDetail")
    )
    #expect(
      reviewsView.contains(
        "HarnessMonitorAccessibility.dashboardReviewsDetailDivider"
      )
    )
    #expect(
      provenanceView.contains("HarnessMonitorAccessibility.dashboardReviewsRefreshButton")
    )
    #expect(
      provenanceView.contains("HarnessMonitorAccessibility.dashboardReviewsInfoButton")
    )
    #expect(
      actionBarView.contains("HarnessMonitorAccessibility.dashboardReviewsFixCIButton")
    )
    #expect(
      actionBarView.contains("HarnessMonitorAccessibility.dashboardReviewsMoreButton")
    )
    #expect(
      controlStripView.contains(
        "HarnessMonitorAccessibility.dashboardReviewsSelectionStatus"
      )
    )
    #expect(reviewsView.contains("SessionContentDetailSplitView("))
  }
}
