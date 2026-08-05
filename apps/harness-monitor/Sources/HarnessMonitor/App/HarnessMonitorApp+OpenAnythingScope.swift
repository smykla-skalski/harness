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
    appOpenAnythingPalette.prioritizesContextDomain = boolPreference(
      OpenAnythingPreferencesDefaults.prioritizeContextKey,
      default: OpenAnythingPreferencesDefaults.prioritizeContextDefault
    )
  }

  func boolPreference(_ key: String, default defaultValue: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
  }

  /// When "Scope to current window" is enabled, derive scope from the window
  /// the palette opens against.
  func scopeDerivedFromWindowID(_ windowID: String?) -> OpenAnythingDomain? {
    guard openAnythingScopeToWindowEnabled else { return nil }
    guard let windowID else { return nil }
    if windowID == HarnessMonitorWindowID.settings {
      return .settings
    }
    return nil
  }

  /// Soft-bias domain for the surface the palette opens from. Unlike
  /// `scopeDerivedFromWindowID`, this never filters: the model floats the
  /// returned domain's section to the top and keeps every other section
  /// visible. The dashboard maps through its active route and Settings maps
  /// to its own domain.
  func contextDomainForActiveView(_ windowID: String?) -> OpenAnythingDomain? {
    guard let windowID else { return nil }
    if windowID == HarnessMonitorWindowID.dashboard {
      return openAnythingContextDomain(
        forDashboardRoute: appWindowNavigationHistory.currentDashboardRoute
      )
    }
    if windowID == HarnessMonitorWindowID.settings {
      return .settings
    }
    return nil
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
    return nil
  }
}

/// Map a dashboard route to the Open Anything domain that should lead when the
/// palette opens from it. Routes without a matching domain return nil so no
/// bias applies. A free function (not a method) so it stays unit-testable
/// without a `HarnessMonitorApp` instance.
func openAnythingContextDomain(
  forDashboardRoute route: DashboardWindowRoute
) -> OpenAnythingDomain? {
  switch route {
  case .reviews:
    return .reviews
  case .taskBoard:
    return .taskBoard
  case .agents, .policyCanvas, .audit, .diagnostics, .debugging:
    return nil
  }
}
