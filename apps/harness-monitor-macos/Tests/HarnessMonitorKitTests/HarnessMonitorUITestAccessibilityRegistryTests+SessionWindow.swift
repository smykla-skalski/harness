import Testing

@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorUITestAccessibilityRegistryTests {
  @Test("Dashboard and session window identifiers match UI-test mirror")
  func dashboardAndSessionWindowIdentifiersMirror() {
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
        == "harness.dashboard.route.dependencies"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardNotificationsRoot
        == "harness.dashboard.notifications"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardNotificationsScrollView
        == "harness.dashboard.notifications.scroll"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesRoot
        == "harness.dashboard.dependencies"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesList
        == "harness.dashboard.dependencies.list"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesDetail
        == "harness.dashboard.dependencies.detail"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesContentDetailDivider
        == "harness.dashboard.dependencies.content-detail-divider"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesRefreshButton
        == "harness.dashboard.dependencies.refresh"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesConfigureButton
        == "harness.dashboard.dependencies.configure"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesFixCIButton
        == "harness.dashboard.dependencies.fix-ci"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardDependenciesSelectionStatus
        == "harness.dashboard.dependencies.selection"
    )
    #expect(
      HarnessMonitorAccessibility.dashboardNotificationRow("toast-success")
        == "harness.dashboard.notifications.row.toast-success"
    )
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
    let dashboardRoot = try sourceFile(named: "DashboardWindowView.swift")
    let dashboardView = try sourceFile(named: "DashboardWindowSupport.swift")
    let dashboardSidebarSessionsView = try sourceFile(
      named: "DashboardSidebarRecentSessionsSection.swift"
    )
    let notificationsView = try sourceFile(named: "DashboardNotificationsRouteView.swift")
    let dependenciesView = try sourceFile(named: "DashboardDependenciesRouteView.swift")
    let dashboardToolbar = try sourceFile(named: "DashboardWindowToolbar.swift")
    let rootView = try sourceFile(named: "SessionWindowRootView.swift")
    let windowView = try sourceFile(named: "SessionWindowView.swift")
    let createRuntimeView = try sourceFile(named: "SessionWindowCreateAgentRuntimePane.swift")
    let sidebarView = try sourceFile(named: "SessionSidebar.swift")
    let sharedSidebarView = try sourceFile(named: "HarnessMonitorSidebar.swift")
    let sidebarFooterView = try sourceFile(named: "SessionSidebarFooter.swift")
    let inspectorView = try sourceFile(named: "SessionWindowInspector.swift")
    let toolbarView = try sourceFile(named: "SessionWindowToolbar.swift")
    let sharedToolbarView = try sourceFile(named: "HarnessMonitorWindowToolbar.swift")

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
    #expect(dashboardView.contains("HarnessMonitorAccessibility.dashboardScrollView"))
    #expect(
      notificationsView.contains("HarnessMonitorAccessibility.dashboardNotificationsScrollView"))
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesRoot")
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesList")
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesDetail")
    )
    #expect(
      dependenciesView.contains(
        "HarnessMonitorAccessibility.dashboardDependenciesContentDetailDivider"
      )
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesRefreshButton")
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesConfigureButton")
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesFixCIButton")
    )
    #expect(
      dependenciesView.contains("HarnessMonitorAccessibility.dashboardDependenciesSelectionStatus")
    )
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardNewSessionButton"))
    #expect(dashboardToolbar.contains("HarnessMonitorAccessibility.dashboardOpenFolderButton"))
    #expect(
      dashboardView.contains("DashboardNotificationsRouteView(")
    )
    #expect(
      dashboardView.contains("DashboardDependenciesRouteView(")
    )
    #expect(dependenciesView.contains("SessionContentDetailSplitView("))
    #expect(dashboardToolbar.contains("SleepPreventionToolbarButton("))
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
