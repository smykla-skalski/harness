import AppKit
import Foundation
import HarnessMonitorUIPreviewable

/// Tracks whether the singleton dashboard window is currently on-screen so
/// the launch router can reopen it on relaunch. Matches the
/// `SessionWindowQuitCapture` contract for session windows: in-memory state
/// is updated by the SwiftUI view lifecycle, then snapshotted to user
/// defaults during termination before `.onDisappear` tears the view down.
@MainActor
final class DashboardWindowLifecycleTracker {
  static let openAtQuitKey = "harness.monitor.dashboard.open-at-quit"
  static let tabbedSessionIDsAtQuitKey = "harness.monitor.dashboard.tabbed-session-ids-at-quit"
  static let wasForegroundTabAtQuitKey = "harness.monitor.dashboard.was-foreground-tab-at-quit"
  static let shared = DashboardWindowLifecycleTracker()

  struct TabRestoreState: Equatable, Sendable {
    let sessionIDs: [String]
    let wasForegroundTab: Bool

    static let empty = TabRestoreState(sessionIDs: [], wasForegroundTab: false)
  }

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
  func flushOpenAtQuit(
    dashboardWindow: NSWindow? = DashboardWindowAppKitRegistry.shared.window,
    sessionBindings: [(window: NSWindow, sessionID: String)] =
      SessionWindowAppKitRegistry.shared.currentBindings()
  ) {
    userDefaults.set(isOpen, forKey: Self.openAtQuitKey)
    let tabRestoreState = Self.resolveTabRestoreState(
      isOpen: isOpen,
      dashboardWindow: dashboardWindow,
      sessionBindings: sessionBindings
    )
    userDefaults.set(tabRestoreState.sessionIDs, forKey: Self.tabbedSessionIDsAtQuitKey)
    userDefaults.set(tabRestoreState.wasForegroundTab, forKey: Self.wasForegroundTabAtQuitKey)
  }

  static func wasOpenAtQuit(userDefaults: UserDefaults = .standard) -> Bool {
    userDefaults.bool(forKey: openAtQuitKey)
  }

  static func tabRestoreStateAtQuit(
    userDefaults: UserDefaults = .standard
  ) -> TabRestoreState {
    let sessionIDs = userDefaults.array(forKey: tabbedSessionIDsAtQuitKey) as? [String] ?? []
    let wasForegroundTab = sessionIDs.isEmpty
      ? false
      : userDefaults.bool(forKey: wasForegroundTabAtQuitKey)
    return TabRestoreState(
      sessionIDs: sessionIDs,
      wasForegroundTab: wasForegroundTab
    )
  }

  private static func resolveTabRestoreState(
    isOpen: Bool,
    dashboardWindow: NSWindow?,
    sessionBindings: [(window: NSWindow, sessionID: String)]
  ) -> TabRestoreState {
    guard isOpen,
      let dashboardWindow,
      let tabGroup = dashboardWindow.tabGroup,
      tabGroup.windows.count > 1
    else {
      return .empty
    }
    let sessionIDs = tabGroup.windows.compactMap { window in
      sessionBindings.first(where: { $0.window === window })?.sessionID
    }
    guard !sessionIDs.isEmpty else {
      return .empty
    }
    return TabRestoreState(
      sessionIDs: sessionIDs,
      wasForegroundTab: tabGroup.selectedWindow === dashboardWindow
    )
  }
}
