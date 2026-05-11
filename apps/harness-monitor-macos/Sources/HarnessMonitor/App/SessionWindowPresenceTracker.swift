import HarnessMonitorKit
import Observation

/// Tracks how many `SessionWindow`s are currently mounted in the running app. The supervisor's
/// notification controller, dock badge, and menu bar status syncs live on the menu-bar extra
/// lifecycle (see `HarnessMonitorApp.init`) so they fire regardless of how many session windows
/// are open at the moment. The tracker now only exists to expose `activeSessionWindowCount` to
/// the menu-bar extra label and similar window-count UI.
@MainActor
@Observable
final class SessionWindowPresenceTracker {
  private(set) var activeSessionWindowCount = 0
  @ObservationIgnored private var activeSessionWindowIDs: Set<ObjectIdentifier> = []

  init() {}

  func sessionWindowAppeared(windowID: ObjectIdentifier) {
    guard activeSessionWindowIDs.insert(windowID).inserted else {
      return
    }
    activeSessionWindowCount = activeSessionWindowIDs.count
  }

  func sessionWindowDisappeared(windowID: ObjectIdentifier) {
    guard activeSessionWindowIDs.remove(windowID) != nil else {
      return
    }
    activeSessionWindowCount = activeSessionWindowIDs.count
  }
}
