import Foundation

/// Tracks whether the singleton Dashboard window is currently on-screen so
/// launch routing can restore that window without retaining Session-window
/// identities.
@MainActor
final class DashboardWindowLifecycleTracker {
  static let openAtQuitKey = "harness.monitor.dashboard.open-at-quit"
  static let shared = DashboardWindowLifecycleTracker()

  private(set) var isOpen = false
  let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
  }

  func markOpen() {
    isOpen = true
  }

  func markClosed() {
    isOpen = false
  }

  func flushOpenAtQuit(userDefaults: UserDefaults? = nil) {
    let defaults = userDefaults ?? self.userDefaults
    SessionWindowRestorationDefaultsMigration.run(userDefaults: defaults)
    defaults.set(isOpen, forKey: Self.openAtQuitKey)
  }

  static func restoreStateAtQuit(
    userDefaults: UserDefaults = .standard
  ) -> Bool? {
    guard userDefaults.object(forKey: openAtQuitKey) != nil else {
      return nil
    }
    return userDefaults.bool(forKey: openAtQuitKey)
  }
}
