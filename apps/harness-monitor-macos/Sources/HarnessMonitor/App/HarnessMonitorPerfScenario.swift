import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

enum HarnessMonitorPerfScenario: String, CaseIterable, Sendable {
  static let environmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  case openRecentWindow = "open-recent-window"
  case openSessionWindow = "open-session-window"
  case agentDetailForm = "agent-detail-form"
  case decisionDetailForm = "decision-detail-form"
  case taskDetailForm = "task-detail-form"
  case sessionSearchFull = "session-search-full"
  case timelineFilterForm = "timeline-filter-form"
  case permissionModal = "permission-modal"
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
    case .openRecentWindow,
      .openSessionWindow,
      .agentDetailForm,
      .taskDetailForm,
      .sessionSearchFull,
      .timelineFilterForm:
      return "dashboard-landing"
    case .decisionDetailForm, .permissionModal:
      return "cockpit"
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return "dashboard"
    case .timelineBurst, .toastOverlayChurn:
      return "dashboard-landing"
    case .offlineCachedOpen:
      return "offline-cached"
    }
  }

  var initialSettingsSection: SettingsSection {
    switch self {
    case .settingsBackdropCycle, .settingsBackgroundCycle:
      return .appearance
    case .openRecentWindow,
      .openSessionWindow,
      .agentDetailForm,
      .decisionDetailForm,
      .taskDetailForm,
      .sessionSearchFull,
      .timelineFilterForm,
      .permissionModal,
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
    let acpPendingOverrideIsEmpty =
      values["HARNESS_MONITOR_PREVIEW_ACP_PENDING"]?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ?? true
    if needsPreviewAcpPermissionBatch, acpPendingOverrideIsEmpty {
      values["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] = "1"
    }
    return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
  }

  private var needsPreviewAcpPermissionBatch: Bool {
    switch self {
    case .decisionDetailForm, .sessionSearchFull, .permissionModal:
      true
    case .openRecentWindow,
      .openSessionWindow,
      .agentDetailForm,
      .taskDetailForm,
      .timelineFilterForm,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      false
    }
  }
}

extension HarnessMonitorPerfScenario {
  var includesBootstrapInMeasurement: Bool {
    switch self {
    case .openRecentWindow:
      true
    case .openSessionWindow,
      .agentDetailForm,
      .decisionDetailForm,
      .taskDetailForm,
      .sessionSearchFull,
      .timelineFilterForm,
      .permissionModal,
      .settingsBackdropCycle,
      .settingsBackgroundCycle,
      .timelineBurst,
      .toastOverlayChurn,
      .offlineCachedOpen:
      false
    }
  }

  var signpostName: StaticString {
    switch self {
    case .openRecentWindow: "open-recent-window"
    case .openSessionWindow: "open-session-window"
    case .agentDetailForm: "agent-detail-form"
    case .decisionDetailForm: "decision-detail-form"
    case .taskDetailForm: "task-detail-form"
    case .sessionSearchFull: "session-search-full"
    case .timelineFilterForm: "timeline-filter-form"
    case .permissionModal: "permission-modal"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .toastOverlayChurn: "toast-overlay-churn"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
