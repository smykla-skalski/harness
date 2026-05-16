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
    openHarnessSessionWindow(sessionID: sessionID, mergeIfNeeded: true)
  }

  @MainActor
  public func openHarnessSessionWindow(
    sessionID: String,
    mergeIfNeeded: Bool
  ) {
    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let tabTargetWindow = mergeIfNeeded
      ? SessionWindowTabbingSupport.visibleTabTargetWindow(
        preference: tabbingPreference
      )
      : nil
    self(
      id: HarnessMonitorWindowID.sessionScene,
      value: SessionWindowToken(sessionID: sessionID)
    )
    guard mergeIfNeeded, let tabTargetWindow else {
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
    openHarnessDashboardWindow(mergeIfNeeded: true)
  }

  @MainActor
  public func openHarnessDashboardWindow(mergeIfNeeded: Bool) {
    let tabbingPreference = SessionWindowTabbingPreference.resolved(
      rawValue: UserDefaults.standard.string(forKey: SessionWindowTabbingPreference.storageKey)
    )
    let tabTargetWindow = mergeIfNeeded
      ? SessionWindowTabbingSupport.visibleTabTargetWindow(
        preference: tabbingPreference
      )
      : nil
    self(id: HarnessMonitorWindowID.dashboard)
    guard mergeIfNeeded, let tabTargetWindow else {
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
    let keyedCandidates = [NSApplication.shared.keyWindow].compactMap { $0 }
    var seenWindowIDs: Set<ObjectIdentifier> = []
    let orderedCandidates = NSApplication.shared.orderedWindows.filter { window in
      seenWindowIDs.insert(ObjectIdentifier(window)).inserted
    }

    for window in keyedCandidates + orderedCandidates {
      guard isTabbedWindowCandidate(window, excluding: targetWindow) else {
        continue
      }
      guard !sharesTabGroup(window, with: targetWindow) else {
        continue
      }
      return window
    }

    return nil
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

  private static func sharesTabGroup(
    _ window: NSWindow,
    with targetWindow: NSWindow
  ) -> Bool {
    guard let targetTabGroup = targetWindow.tabGroup else {
      return false
    }
    return targetTabGroup === window.tabGroup
  }
}
