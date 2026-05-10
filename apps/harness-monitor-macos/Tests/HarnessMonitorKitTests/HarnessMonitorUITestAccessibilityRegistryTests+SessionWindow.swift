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

  @Test("Session window accessibility identifiers are attached by production views")
  func sessionWindowAccessibilityIdentifiersAreAttachedByProductionViews() throws {
    let openRecentView = try sourceFile(named: "OpenRecentView.swift")
    let rootView = try sourceFile(named: "SessionWindowRootView.swift")
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let createRuntimeView = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
    let sidebarView = try sourceFile(named: "SessionSidebar.swift")
    let inspectorView = try sourceFile(named: "SessionWindowInspector.swift")
    let toolbarView = try sourceFile(named: "SessionWindowToolbar.swift")

    #expect(openRecentView.contains("HarnessMonitorAccessibility.openRecentRoot"))
    #expect(openRecentView.contains("HarnessMonitorAccessibility.openRecentSessionRow"))
    #expect(
      openRecentView.contains(
        "accessibilityMarkerID: HarnessMonitorAccessibility.openRecentProjectList"
      )
    )
    #expect(
      !openRecentView.contains(
        ".accessibilityIdentifier(HarnessMonitorAccessibility.openRecentProjectList)"
      )
    )
    #expect(windowView.contains("HarnessMonitorAccessibility.sessionWindowShell"))
    #expect(
      rootView.contains(
        "HarnessMonitorAccessibility.sessionWindowToolbarSeparatorSuppressed"
      )
    )
    #expect(sidebarView.contains("HarnessMonitorAccessibility.sessionWindowSidebar"))
    #expect(
      createRuntimeView.contains("HarnessMonitorAccessibility.sessionWindowCreateProviderPane"))
    #expect(
      createRuntimeView.contains(
        ".accessibilityTestProbe(\n      HarnessMonitorAccessibility.sessionWindowCreateProviderPane"
      )
    )
    #expect(!createRuntimeView.contains("sessionWindowCreateModePicker"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionWindowFocusModeButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateBackButton"))
    #expect(toolbarView.contains("HarnessMonitorAccessibility.sessionNavigateForwardButton"))
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
