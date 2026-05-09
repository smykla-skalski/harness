extension HarnessMonitorUITestAccessibility {
  static let openRecentRoot = "harness.open.recent"
  static let openRecentProjectList = "harness.open.recent.projects"
  static let openRecentOpenFolderButton = "harness.open.recent.open-folder"
  static let openRecentActionState = "harness.open.recent.action-state"
  static let sessionWindowShell = "harness.session.window"
  static let sessionWindowSidebar = "harness.session.window.sidebar"
  static let sessionNavigateBackButton = "harness.session.window.toolbar.navigate-back"
  static let sessionNavigateForwardButton = "harness.session.window.toolbar.navigate-forward"
  static let sessionWindowFocusModeButton = "harness.session.window.toolbar.focus-mode"
  static let sessionWindowStatusMenu = "harness.session.window.toolbar.status"
  static let sessionWindowToolbarSeparatorSuppressed =
    "harness.session.window.toolbar.separator-suppressed"
  static let sessionWindowCreateProviderPane =
    "harness.session.window.create.provider-pane"
  static let sessionWindowInspector = "harness.session.window.inspector"
  static let sessionWindowInspectorCloseButton = "harness.session.window.inspector.close"
  static let settingsLaunchBehaviorPicker = "harness.settings.launch-behavior"

  static func openRecentSessionRow(_ sessionID: String) -> String {
    "harness.open.recent.session.\(slug(sessionID))"
  }

  static func sessionWindowRoute(_ route: String) -> String {
    "harness.session.window.route.\(slug(route))"
  }
}
