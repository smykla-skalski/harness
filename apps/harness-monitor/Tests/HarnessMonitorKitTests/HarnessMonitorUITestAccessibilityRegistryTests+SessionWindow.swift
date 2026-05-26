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
      HarnessMonitorAccessibility.dashboardNotificationsRoot
        == "harness.dashboard.notifications"
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
      HarnessMonitorAccessibility.dashboardDebuggingOCRResultList
        == "harness.dashboard.debugging.ocr.results"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardNotificationsScrollView
        == "harness.dashboard.notifications.scroll"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardNotificationRow("toast-success")
        == "harness.dashboard.notifications.row.toast-success"
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
    let notificationsView = try sourceFile(named: "DashboardNotificationsRouteView.swift")
    let diagnosticsView = try sourceFile(named: "DashboardDiagnosticsRouteView.swift")
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
    #expect(
      notificationsView.contains("HarnessMonitorAccessibility.dashboardNotificationsRoot")
    )
    #expect(diagnosticsView.contains("HarnessMonitorAccessibility.dashboardDiagnosticsRoot"))
    #expect(dashboardView.contains("HarnessMonitorSidebar("))
    #expect(dashboardView.contains("List(selection: dashboardSelectionBinding)"))
    #expect(dashboardView.contains("SessionSidebarRow("))
    #expect(!dashboardView.contains("Section(\"Routes\")"))
    #expect(dashboardView.contains("DashboardSidebarRecentSessionsSection("))
    #expect(dashboardSidebarSessionsView.contains("Section(\"Sessions\")"))
    #expect(dashboardSidebarSessionsView.contains("SessionSidebarRow("))
    #expect(dashboardSidebarSessionsView.contains("subtitle: subtitle"))
    #expect(
      dashboardSidebarSessionsView.contains("projectAndWorktreeDisplayLabel(separator: \"·\")"))
    #expect(dashboardView.contains(".harnessMonitorSidebarListChrome("))
    #expect(dashboardRouteContent.contains("HarnessMonitorAccessibility.dashboardScrollView"))
    #expect(
      notificationsView.contains("HarnessMonitorAccessibility.dashboardNotificationsScrollView"))
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardNewSessionButton"))
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardOpenFolderButton"))
    #expect(dashboardRouteContent.contains("DashboardNotificationsRouteView("))
    #expect(dashboardRouteContent.contains("DashboardReviewsRouteView("))
    #expect(dashboardToolbar.contains("SleepPreventionToolbarButton("))
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

  private func expectSessionWindowIdentifierUsage() throws {
    let rootView = try sourceFile(named: "SessionWindowRootView.swift")
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let createRuntimeView = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
    let sidebarView = try sourceFile(named: "SessionSidebar.swift")
    let sharedSidebarView = try sourceFile(named: "HarnessMonitorSidebar.swift")
    let sidebarFooterView = try sourceFile(named: "SessionSidebarFooter.swift")
    let inspectorView = try sourceFile(named: "SessionWindowInspector.swift")
    let toolbarView = try sourceFile(named: "SessionWindowToolbar.swift")
    let sharedToolbarView = try sourceFile(named: "HarnessMonitorWindowToolbar.swift")

    #expect(windowView.contains("HarnessMonitorAccessibility.sessionWindowShell"))
    #expect(
      rootView.contains(
        "HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed"
      )
    )
    #expect(sidebarView.contains("HarnessMonitorAccessibility.sessionWindowSidebar"))
    #expect(sidebarView.contains("HarnessMonitorSidebar("))
    #expect(sidebarView.contains("accessibilityValue: decisionSelectionAccessibilityValue"))
    #expect(sidebarView.contains(".harnessMonitorSidebarListChrome(rowSize: sidebarRowSize)"))
    #expect(sharedSidebarView.contains("HarnessMonitorSidebarListChromeModifier"))
    #expect(sharedSidebarView.contains("SessionSidebarFooter(model: statusModel)"))
    #expect(sharedSidebarView.contains(".accessibilityIdentifier(accessibilityIdentifier)"))
    #expect(sharedSidebarView.contains(".accessibilityValue(accessibilityValue)"))
    #expect(
      sidebarFooterView.contains("HarnessMonitorAccessibility.sessionWindowStatusSurface")
    )
    #expect(sidebarFooterView.contains(".harnessMCPText("))
    #expect(
      createRuntimeView.contains("HarnessMonitorAccessibility.sessionWindowCreateProviderPane"))
    #expect(
      createRuntimeView.contains(
        ".accessibilityTestProbe(\n      HarnessMonitorAccessibility.sessionWindowCreateProviderPane"
      )
    )
    #expect(!createRuntimeView.contains("sessionWindowCreateModePicker"))
    #expect(toolbarView.contains(".harnessMCPButton("))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionWindowFocusModeButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateBackButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateForwardButton"))
    #expect(toolbarView.contains("HarnessMonitorWindowToolbar {"))
    #expect(sharedToolbarView.contains("struct HarnessMonitorWindowToolbar<"))
    #expect(
      inspectorView.contains(
        ".accessibilityTestProbe(\n      HarnessMonitorAccessibility.sessionWindowInspector"
      )
    )
    #expect(
      !inspectorView.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.sessionWindowInspector)"
      )
    )
    #expect(
      inspectorView.contains(
        "HarnessMonitorAccessibility.sessionWindowInspectorCloseButton"
      )
    )
  }
}
