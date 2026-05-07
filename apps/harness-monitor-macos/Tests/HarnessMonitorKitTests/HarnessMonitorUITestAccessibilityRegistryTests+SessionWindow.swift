import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Open recent and session window identifiers match UI-test mirror")
  func openRecentAndSessionWindowIdentifiersMirror() {
    #expect(HarnessMonitorAccessibility.openRecentRoot == "harness.open.recent")
    #expect(
      HarnessMonitorAccessibility.openRecentProjectList
        == "harness.open.recent.projects"
    )
    #expect(
      HarnessMonitorAccessibility.openRecentRefreshButton
        == "harness.open.recent.refresh"
    )
    #expect(
      HarnessMonitorAccessibility.openRecentOpenFolderButton
        == "harness.open.recent.open-folder"
    )
    #expect(
      HarnessMonitorAccessibility.openRecentActionState
        == "harness.open.recent.action-state"
    )
    #expect(
      HarnessMonitorAccessibility.openRecentSessionRow("sess alpha")
        == "harness.open.recent.session.sess-alpha"
    )
    #expect(HarnessMonitorAccessibility.sessionWindowShell == "harness.session.window")
    #expect(
      HarnessMonitorAccessibility.sessionWindowSidebar
        == "harness.session.window.sidebar"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowStatusMenu
        == "harness.session.window.toolbar.status"
    )
    #expect(
      HarnessMonitorAccessibility.sessionWindowRoute(.decisions)
        == "harness.session.window.route.decisions"
    )
    #expect(
      HarnessMonitorAccessibility.settingsLaunchBehaviorPicker
        == "harness.settings.launch-behavior"
    )
  }
}
