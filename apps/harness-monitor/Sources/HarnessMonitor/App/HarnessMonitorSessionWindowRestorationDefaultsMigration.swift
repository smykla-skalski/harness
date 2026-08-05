import Foundation

enum SessionWindowRestorationDefaultsMigration {
  static let bridgeFallbackKey =
    "harness.monitor.launch-window.bridge-fallback-done"
  static let tabbedSessionIDsKey =
    "harness.monitor.dashboard.tabbed-session-ids-at-quit"
  static let dashboardWasForegroundTabKey =
    "harness.monitor.dashboard.was-foreground-tab-at-quit"

  static func run(userDefaults: UserDefaults = .standard) {
    userDefaults.removeObject(forKey: bridgeFallbackKey)
    userDefaults.removeObject(forKey: tabbedSessionIDsKey)
    userDefaults.removeObject(forKey: dashboardWasForegroundTabKey)
  }
}
