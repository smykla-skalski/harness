enum MonitorAccessibility {
  static let daemonCard = "monitor.sidebar.daemon-card"
  static let onboardingCard = "monitor.board.onboarding-card"
  static let preferencesRoot = "monitor.preferences.root"
  static let refreshButton = "monitor.toolbar.refresh"
  static let daemonPreferencesButton = "monitor.toolbar.preferences"

  static func sessionRow(_ sessionID: String) -> String {
    "monitor.sidebar.session.\(sessionID)"
  }
}
