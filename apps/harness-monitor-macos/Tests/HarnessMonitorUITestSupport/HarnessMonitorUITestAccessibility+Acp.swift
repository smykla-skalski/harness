extension HarnessMonitorUITestAccessibility {
  static let decisionAcpDeadline = "harness.decisions.context.acp.deadline"
  static let decisionAcpPanel = "harness.decisions.context.acp"
  static let decisionAcpSelectionSummary = "harness.decisions.context.acp.selection-summary"
  static let decisionAcpError = "harness.decisions.context.acp.error"

  static let acpPermissionModal = "harness.acp-permission.modal"
  static let acpPermissionModalSelectionSummary = "harness.acp-permission.selection-summary"
  static let acpPermissionModalOpenWorkspace = "harness.acp-permission.open-workspace"
  static let acpPermissionModalClose = "harness.acp-permission.close"

  static func decisionDeadline(_ id: String) -> String {
    "harness.decisions.deadline.\(slug(id))"
  }

  static func decisionAcpRequest(_ id: String) -> String {
    "harness.decisions.context.acp.request.\(slug(id))"
  }

  static func acpPermissionModalItem(_ id: String) -> String {
    "harness.acp-permission.item.\(slug(id))"
  }

  static let newSessionSheet = "harness.new-session.sheet"
  static let newSessionTitle = "harness.new-session.title"
  static let newSessionContext = "harness.new-session.context"
  static let newSessionBaseRef = "harness.new-session.base-ref"
  static let newSessionProjectPicker = "harness.new-session.project-picker"
  static let newSessionTabPicker = "harness.new-session.tab-picker"
  static let newSessionCreateTab = "harness.new-session.tab.create.control"
  static let newSessionRuntimeTab = "harness.new-session.tab.runtime.control"
  static let newSessionCreatePanel = "harness.new-session.tab.create.panel"
  static let newSessionRuntimePanel = "harness.new-session.tab.runtime.panel"
  static let newSessionCapabilityPickerSection = "harness.new-session.capability-picker.section"
  static let newSessionCapabilityPicker = "harness.new-session.capability-picker"
  static let newSessionCreateDisabledReason = "harness.new-session.create-disabled-reason"
  static let newSessionCreateButton = "harness.new-session.create-button"
  static let newSessionCancelButton = "harness.new-session.cancel-button"
  static let newSessionErrorBanner = "harness.new-session.error-banner"

  static func newSessionCapabilityRow(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier))"
  }

  static func newSessionCapabilityProbe(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier)).probe"
  }

  static func newSessionCapabilityTransportButton(
    _ identifier: String,
    transportID: String
  ) -> String {
    "harness.new-session.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  static func newSessionDiagnosticsToggle(_ identifier: String) -> String {
    "harness.new-session.capability.\(slug(identifier)).diagnostics-toggle"
  }
}
