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
}
