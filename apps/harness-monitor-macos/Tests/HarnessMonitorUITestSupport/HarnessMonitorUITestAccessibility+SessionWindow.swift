extension HarnessMonitorUITestAccessibility {
  static let welcomeRecentsRoot = "harness.welcome.recents"
  static let welcomeRecentsProjectList = "harness.welcome.recents.projects"
  static let sessionWindowShell = "harness.session.window"
  static let sessionWindowSidebar = "harness.session.window.sidebar"
  static let sessionWindowStatusMenu = "harness.session.window.toolbar.status"
  static let settingsLaunchBehaviorPicker = "harness.settings.launch-behavior"

  static func welcomeRecentSessionRow(_ sessionID: String) -> String {
    "harness.welcome.recents.session.\(slug(sessionID))"
  }

  static func sessionWindowRoute(_ route: String) -> String {
    "harness.session.window.route.\(slug(route))"
  }
}
