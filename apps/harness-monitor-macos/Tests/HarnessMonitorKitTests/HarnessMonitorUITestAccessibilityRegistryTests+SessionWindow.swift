import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Welcome recents and session window identifiers match UI-test mirror")
  func welcomeRecentsAndSessionWindowIdentifiersMirror() {
    #expect(HarnessMonitorAccessibility.welcomeRecentsRoot == "harness.welcome.recents")
    #expect(
      HarnessMonitorAccessibility.welcomeRecentsProjectList
        == "harness.welcome.recents.projects"
    )
    #expect(
      HarnessMonitorAccessibility.welcomeRecentSessionRow("sess alpha")
        == "harness.welcome.recents.session.sess-alpha"
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
