import AppKit
import HarnessMonitorKit
import HarnessMonitorUIPreviewable
import SwiftUI

extension HarnessMonitorApp {
  /// Push Settings values into the palette model just before presenting so the
  /// next search and suggested lane honor live preferences.
  func applyOpenAnythingPreferences() {
    let defaults = UserDefaults.standard
    let storedLimit =
      defaults.object(
        forKey: OpenAnythingPreferencesDefaults.perDomainLimitKey
      ) as? Int ?? OpenAnythingPreferencesDefaults.perDomainLimitDefault
    let clamped = max(
      OpenAnythingPreferencesDefaults.perDomainLimitMin,
      min(OpenAnythingPreferencesDefaults.perDomainLimitMax, storedLimit)
    )
    appOpenAnythingPalette.limitPerDomain = clamped
    appOpenAnythingPalette.showsPinned = boolPreference(
      OpenAnythingPreferencesDefaults.showPinnedKey,
      default: OpenAnythingPreferencesDefaults.showPinnedDefault
    )
    appOpenAnythingPalette.showsRecent = boolPreference(
      OpenAnythingPreferencesDefaults.showRecentKey,
      default: OpenAnythingPreferencesDefaults.showRecentDefault
    )
    appOpenAnythingPalette.keepsPaletteOpenOnCommandClick = boolPreference(
      OpenAnythingPreferencesDefaults.cmdClickBackgroundKey,
      default: OpenAnythingPreferencesDefaults.cmdClickBackgroundDefault
    )
  }

  func boolPreference(_ key: String, default defaultValue: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
  }

  /// When "Scope to current window" is enabled, derive scope from the window
  /// the palette opens against. Session windows only scope when their slug
  /// resolves to a real session ID, avoiding wrong-session results.
  func scopeDerivedFromWindowID(_ windowID: String?) -> OpenAnythingDomain? {
    guard openAnythingScopeToWindowEnabled else { return nil }
    guard let windowID else { return nil }
    if windowID == HarnessMonitorWindowID.settings {
      return .settings
    }
    if openAnythingSessionID(forWindowID: windowID) != nil {
      return .loadedSession
    }
    return nil
  }

  func openAnythingSessionID(forWindowID windowID: String?) -> String? {
    guard openAnythingScopeToWindowEnabled, let windowID else { return nil }
    if let selectedSessionID = appStore.selectedSessionID,
      HarnessMonitorWindowID.sessionWindow(selectedSessionID) == windowID
    {
      return selectedSessionID
    }
    return appStore.sessions.first { session in
      HarnessMonitorWindowID.sessionWindow(session.sessionId) == windowID
    }?.sessionId
  }

  func prepareOpenAnythingLoadedSessionOverride(sessionID: String?) {
    guard let sessionID else {
      appOpenAnythingLoadedSessionOverride = nil
      return
    }
    appOpenAnythingLoadedSessionOverride = OpenAnythingLoadedSessionSnapshot(
      sessionID: sessionID,
      agents: [],
      tasks: [],
      timeline: []
    )
    Task { @MainActor in
      guard
        let snapshot = await appStore.sessionWindowSnapshot(sessionID: sessionID),
        openAnythingSessionID(forWindowID: openAnythingTargetWindowID()) == sessionID
      else {
        return
      }
      appOpenAnythingLoadedSessionOverride = OpenAnythingLoadedSessionSnapshot(
        sessionID: sessionID,
        agents: snapshot.detail?.agents ?? [],
        tasks: snapshot.detail?.tasks ?? [],
        timeline: snapshot.timeline
      )
    }
  }

  var openAnythingScopeToWindowEnabled: Bool {
    UserDefaults.standard.bool(forKey: OpenAnythingPreferencesDefaults.scopeToWindowKey)
  }

  // Use `KeyWindowObserver.isKey(windowID:)` for every candidate so the matcher
  // stays consistent with the observer that gates shared-shell visibility.
  func openAnythingTargetWindowID() -> String? {
    let observer = keyWindowObserver
    if observer.isKey(windowID: HarnessMonitorWindowID.dashboard) {
      return HarnessMonitorWindowID.dashboard
    }
    if observer.isKey(windowID: HarnessMonitorWindowID.settings) {
      return HarnessMonitorWindowID.settings
    }
    if observer.isKey(windowID: HarnessMonitorWindowID.policyCanvasLab) {
      return HarnessMonitorWindowID.policyCanvasLab
    }
    if let identifier = observer.snapshot.keyWindowIdentifier,
      identifier.hasPrefix("session-")
    {
      return identifier
    }
    return nil
  }

  func focusDashboardWindowIfPossible() {
    if #available(macOS 14.0, *) {
      NSApplication.shared.activate()
    } else {
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    DashboardWindowAppKitRegistry.shared.window?.makeKeyAndOrderFront(nil)
  }
}
