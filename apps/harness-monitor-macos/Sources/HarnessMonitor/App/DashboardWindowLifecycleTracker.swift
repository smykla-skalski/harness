import Foundation

/// Tracks whether the singleton dashboard window is currently on-screen so
/// the launch router can reopen it on relaunch. Matches the
/// `SessionWindowQuitCapture` contract for session windows: in-memory state
/// is updated by the SwiftUI view lifecycle, then snapshotted to user
/// defaults during termination before `.onDisappear` tears the view down.
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

  /// Snapshot the live state to user defaults. Called from
  /// `applicationShouldTerminate` and the signal-termination path so the
  /// value persists even when SwiftUI tears the view down after we reply.
  func flushOpenAtQuit() {
    userDefaults.set(isOpen, forKey: Self.openAtQuitKey)
  }

  static func wasOpenAtQuit(userDefaults: UserDefaults = .standard) -> Bool {
    userDefaults.bool(forKey: openAtQuitKey)
  }
}
