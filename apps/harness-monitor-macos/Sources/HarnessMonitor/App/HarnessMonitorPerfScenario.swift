import Foundation
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

enum HarnessMonitorPerfScenario: String, CaseIterable, Sendable {
  static let environmentKey = "HARNESS_MONITOR_PERF_SCENARIO"

  case openRecentWindow = "open-recent-window"
  case openSessionWindow = "open-session-window"
  case openSessionWindowVisualOptionsDisabled = "open-session-window-visual-options-disabled"
  case agentDetailForm = "agent-detail-form"
  case agentDetailFormVisualOptionsDisabled = "agent-detail-form-visual-options-disabled"
  case decisionDetailForm = "decision-detail-form"
  case decisionDetailFormVisualOptionsDisabled = "decision-detail-form-visual-options-disabled"
  case taskDetailForm = "task-detail-form"
  case taskDetailFormVisualOptionsDisabled = "task-detail-form-visual-options-disabled"
  case sessionSearchFull = "session-search-full"
  case sessionSearchFullVisualOptionsDisabled = "session-search-full-visual-options-disabled"
  case sidebarToggleRichDetail = "sidebar-toggle-rich-detail"
  case sidebarToggleRichDetailVisualsOff =
    "sidebar-toggle-rich-detail-visual-options-disabled"
  case timelineFilterForm = "timeline-filter-form"
  case timelineFilterFormVisualOptionsDisabled = "timeline-filter-form-visual-options-disabled"
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
      .openSessionWindowVisualOptionsDisabled,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled:
      return "dashboard-landing"
    case .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .permissionModal:
      return "cockpit"
    case .settingsBackdropCycle,
      .settingsBackgroundCycle:
      return "dashboard"
    case .timelineBurst, .toastOverlayChurn:
      return "dashboard-landing"
    case .offlineCachedOpen:
      return "offline-cached"
    }
  }

  var initialSettingsSection: SettingsSection {
    switch self {
    case .settingsBackdropCycle,
      .settingsBackgroundCycle:
      return .appearance
    case .openRecentWindow,
      .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
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
    applyVisualOptionDefaults(to: &values)
    return HarnessMonitorEnvironment(values: values, homeDirectory: environment.homeDirectory)
  }

  private func applyVisualOptionDefaults(to values: inout [String: String]) {
    guard disablesVisualOptions else {
      return
    }
    values[HarnessMonitorAppConfiguration.sessionShortcutOverlaysOverrideKey] = "0"
    values[HarnessMonitorAppConfiguration.sessionTitleBlurOverrideKey] = "0"
    values[HarnessMonitorAppConfiguration.menuBarStateColorsOverrideKey] = "0"
    values["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE"] = HarnessMonitorBackdropMode.none.rawValue
  }

  private var disablesVisualOptions: Bool {
    switch self {
    case .openSessionWindowVisualOptionsDisabled,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterFormVisualOptionsDisabled:
      true
    case .openRecentWindow,
      .openSessionWindow,
      .agentDetailForm,
      .decisionDetailForm,
      .taskDetailForm,
      .sessionSearchFull,
      .sidebarToggleRichDetail,
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

  private var needsPreviewAcpPermissionBatch: Bool {
    switch self {
    case .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .permissionModal:
      true
    case .openRecentWindow,
      .openSessionWindow,
      .openSessionWindowVisualOptionsDisabled,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
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
      .openSessionWindowVisualOptionsDisabled,
      .agentDetailForm,
      .agentDetailFormVisualOptionsDisabled,
      .decisionDetailForm,
      .decisionDetailFormVisualOptionsDisabled,
      .taskDetailForm,
      .taskDetailFormVisualOptionsDisabled,
      .sessionSearchFull,
      .sessionSearchFullVisualOptionsDisabled,
      .sidebarToggleRichDetail,
      .sidebarToggleRichDetailVisualsOff,
      .timelineFilterForm,
      .timelineFilterFormVisualOptionsDisabled,
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
    case .openSessionWindowVisualOptionsDisabled: "open-session-window-visual-options-disabled"
    case .agentDetailForm: "agent-detail-form"
    case .agentDetailFormVisualOptionsDisabled: "agent-detail-form-visual-options-disabled"
    case .decisionDetailForm: "decision-detail-form"
    case .decisionDetailFormVisualOptionsDisabled: "decision-detail-form-visual-options-disabled"
    case .taskDetailForm: "task-detail-form"
    case .taskDetailFormVisualOptionsDisabled: "task-detail-form-visual-options-disabled"
    case .sessionSearchFull: "session-search-full"
    case .sessionSearchFullVisualOptionsDisabled: "session-search-full-visual-options-disabled"
    case .sidebarToggleRichDetail: "sidebar-toggle-rich-detail"
    case .sidebarToggleRichDetailVisualsOff:
      "sidebar-toggle-rich-detail-visual-options-disabled"
    case .timelineFilterForm: "timeline-filter-form"
    case .timelineFilterFormVisualOptionsDisabled: "timeline-filter-form-visual-options-disabled"
    case .permissionModal: "permission-modal"
    case .settingsBackdropCycle: "settings-backdrop-cycle"
    case .settingsBackgroundCycle: "settings-background-cycle"
    case .timelineBurst: "timeline-burst"
    case .toastOverlayChurn: "toast-overlay-churn"
    case .offlineCachedOpen: "offline-cached-open"
    }
  }
}
