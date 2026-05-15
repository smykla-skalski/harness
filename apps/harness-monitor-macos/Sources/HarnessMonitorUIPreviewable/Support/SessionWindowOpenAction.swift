import AppKit
import HarnessMonitorKit
import SwiftUI

extension OpenWindowAction {
  @MainActor
  public func openHarnessSessionWindow(sessionID: String?) {
    guard let sessionID, !sessionID.isEmpty else {
      openHarnessDashboardWindow()
      return
    }
    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let tabTargetWindow = SessionWindowTabbingSupport.visibleTabTargetWindow(
      preference: tabbingPreference
    )
    self(
      id: HarnessMonitorWindowID.sessionScene,
      value: SessionWindowToken(sessionID: sessionID)
    )
    guard let tabTargetWindow else {
      return
    }
    Task { @MainActor in
      await SessionWindowTabMergeCoordinator.mergeNewestTabbedWindowIfNeeded(
        into: tabTargetWindow,
        preference: tabbingPreference
      )
    }
  }

  @MainActor
  public func openHarnessDashboardWindow() {
    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let tabTargetWindow = SessionWindowTabbingSupport.visibleTabTargetWindow(
      preference: tabbingPreference
    )
    self(id: HarnessMonitorWindowID.dashboard)
    guard let tabTargetWindow else {
      return
    }
    Task { @MainActor in
      await SessionWindowTabMergeCoordinator.mergeNewestTabbedWindowIfNeeded(
        into: tabTargetWindow,
        preference: tabbingPreference
      )
    }
  }

  @MainActor
  public func openHarnessDecisionSession(
    decisionID: String,
    store: HarnessMonitorStore
  ) {
    let sessionID =
      store.supervisorOpenDecisions.first { $0.id == decisionID }?.sessionID
      ?? store.acpPermissionDecisionPayload(for: decisionID)?.rawBatch.sessionId
      ?? store.selectedSessionID
    if let sessionID, store.openSessionWindowIDsSnapshot.contains(sessionID) {
      if #available(macOS 14.0, *) {
        NSApplication.shared.activate()
      } else {
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
      return
    }
    openHarnessSessionWindow(sessionID: sessionID)
  }
}

@MainActor
enum SessionWindowTabMergeCoordinator {
  static func mergeNewestTabbedWindowIfNeeded(
    into targetWindow: NSWindow,
    preference: SessionWindowTabbingPreference
  ) async {
    guard
      SessionWindowTabbingSupport.shouldPreferTabbedOpen(
        preference: preference,
        targetIsFullScreen: targetWindow.styleMask.contains(.fullScreen)
      )
    else {
      return
    }

    SessionWindowTabbingSupport.prepareWindowForTabbing(
      targetWindow,
      preference: preference
    )

    for _ in 0..<6 {
      await Task.yield()
      if let candidateWindow = candidateWindow(for: targetWindow) {
        SessionWindowTabbingSupport.prepareWindowForTabbing(
          candidateWindow,
          preference: preference
        )
        if targetWindow.tabGroup != nil, targetWindow.tabGroup === candidateWindow.tabGroup {
          return
        }
        targetWindow.addTabbedWindow(candidateWindow, ordered: .above)
        return
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  private static func candidateWindow(for targetWindow: NSWindow) -> NSWindow? {
    if let keyWindow = NSApplication.shared.keyWindow,
      isTabbedWindowCandidate(keyWindow, excluding: targetWindow)
    {
      return keyWindow
    }

    return NSApplication.shared.orderedWindows.first {
      isTabbedWindowCandidate($0, excluding: targetWindow)
    }
  }

  private static func isTabbedWindowCandidate(
    _ window: NSWindow,
    excluding targetWindow: NSWindow
  ) -> Bool {
    window !== targetWindow
      && window.isVisible
      && !window.isMiniaturized
      && window.tabbingIdentifier == SessionWindowTabbingSupport.tabbingIdentifier
  }
}
