import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

enum HarnessMonitorPerfScenario: String, CaseIterable, Sendable {
  static let environmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  case launchDashboard = "launch-dashboard"
  case selectSessionCockpit = "select-session-cockpit"
  case refreshAndSearch = "refresh-and-search"
  case sidebarOverflowSearch = "sidebar-overflow-search"
  case settingsBackdropCycle = "settings-backdrop-cycle"
  case settingsBackgroundCycle = "settings-background-cycle"
  case timelineBurst = "timeline-burst"
  case toastOverlayChurn = "toast-overlay-churn"
  case offlineCachedOpen = "offline-cached-open"

  init?(environment: HarnessMonitorEnvironment) {
    let rawValue = environment.values[Self.environmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard let rawValue, !rawValue.isEmpty else {
      return nil
    }
    self.init(rawValue: rawValue)
  }

  var defaultPreviewScenario: String {
    switch self {
    case .launchDashboard, .selectSessionCockpit:
      return "dashboard-landing"
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return "dashboard"
    case .refreshAndSearch, .sidebarOverflowSearch:
      return "overflow"
    case .timelineBurst, .toastOverlayChurn:
      return "cockpit"
    case .offlineCachedOpen:
      return "offline-cached"
    }
  }

  var initialPreferencesSection: PreferencesSection {
    switch self {
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return .appearance
    case .launchDashboard,
      .selectSessionCockpit,
      .refreshAndSearch,
      .sidebarOverflowSearch,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      return .general
    }
  }

  func applyingDefaults(to environment: HarnessMonitorEnvironment) -> HarnessMonitorEnvironment {
    var values = environment.values
    if values[HarnessMonitorLaunchMode.environmentKey]?.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    .isEmpty ?? true {
      values[HarnessMonitorLaunchMode.environmentKey] = HarnessMonitorLaunchMode.preview.rawValue
    }
    let previewScenarioIsEmpty =
      values["HARNESS_MONITOR_PREVIEW_SCENARIO"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ?? true
    if previewScenarioIsEmpty {
      values["HARNESS_MONITOR_PREVIEW_SCENARIO"] = defaultPreviewScenario
    }
    let inspectorOverrideIsEmpty =
      values["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ?? true
    if self == .launchDashboard, inspectorOverrideIsEmpty {
      values["HARNESS_MONITOR_SHOW_INSPECTOR_OVERRIDE"] = "0"
    }
    return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
  }
}
