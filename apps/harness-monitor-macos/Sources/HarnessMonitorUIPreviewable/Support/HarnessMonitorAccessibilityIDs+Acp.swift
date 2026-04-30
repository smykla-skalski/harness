import SwiftUI

extension HarnessMonitorAccessibility {
  public static let contentAcpBridgeBanner = "harness.content.acp-bridge.banner"
  public static let contentAcpBridgeOpenLogButton = "harness.content.acp-bridge.open-log"
  public static let contentAcpBridgeRunDoctorButton = "harness.content.acp-bridge.run-doctor"

  public static let preferencesAcpNotificationStatus = "harness.preferences.acp.status"
  public static let preferencesAcpNotificationStatusState = "harness.preferences.acp.status.state"
  public static let preferencesAcpCatalogToggle = "harness.preferences.acp.catalog.toggle"
  public static let preferencesAcpCatalogPermission = "harness.preferences.acp.catalog.permission"
  public static let preferencesAcpVerboseAnnounceToggle =
    "harness.preferences.acp.verbose-tool-call-announcements"
  public static let preferencesAcpOpenSystemSettings =
    "harness.preferences.acp.open-system-settings"

  public static let acpPermissionToast = "harness.acp-permission.toast"
  public static let acpPermissionToastFrame = "harness.acp-permission.toast.frame"
  public static let acpPermissionToastState = "harness.acp-permission.toast.state"
  public static let acpPermissionToastAccessibilityState =
    "harness.acp-permission.toast.accessibility.state"
  public static let toolCallTimelineAccessibilityState =
    "harness.window.agents.tool-call-timeline.accessibility.state"
  public static let agentRuntimeWatchdogAccessibilityState =
    "harness.agents.detail.runtime.watchdog.accessibility.state"
  public static let acpPermissionToastRouteState = "harness.acp-permission.toast.route.state"
  public static let acpPermissionToastActionButton =
    "harness.acp-permission.toast.open-decisions"
  public static let acpPermissionToastCloseButton = "harness.acp-permission.toast.close"

  public static let agentsCodexModelPicker = "harness.window.agents.codex.model"
  public static let agentsCodexCustomModelField = "harness.window.agents.codex.model.custom"
  public static let agentsCodexEffortPicker = "harness.window.agents.codex.effort"
  public static let agentsCodexPromptField = "harness.window.agents.codex.prompt"
  public static let agentsCodexContextField = "harness.window.agents.codex.context"
  public static let agentsCodexModePicker = "harness.window.agents.codex.mode"
  public static let agentsCodexSubmitButton = "harness.window.agents.codex.submit"
  public static let agentsCodexSteerButton = "harness.window.agents.codex.steer"
  public static let agentsCodexInterruptButton = "harness.window.agents.codex.interrupt"
  public static let agentsCodexFinalMessage = "harness.window.agents.codex.final"
  public static let agentsCodexLatestSummary = "harness.window.agents.codex.latest"
  public static let agentsCodexErrorMessage = "harness.window.agents.codex.error"
  public static let agentsCodexRecoveryBanner = "harness.window.agents.codex.recovery-banner"
  public static let agentsCodexEnableBridgeButton = "harness.window.agents.codex.enable-bridge"
  public static let agentsCodexCopyCommandButton = "harness.window.agents.codex.copy-command"
  public static let agentsAcpRecoveryBanner = "harness.window.agents.acp.recovery-banner"
  public static let agentsAcpEnableBridgeButton = "harness.window.agents.acp.enable-bridge"
  public static let agentsAcpCopyCommandButton = "harness.window.agents.acp.copy-command"

  public static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier))"
  }

  public static func agentCapabilityInstallButton(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier)).install"
  }

  public static func agentCapabilityProbe(_ identifier: String) -> String {
    "harness.window.agents.capability.\(slug(identifier)).probe"
  }

  public static func agentCapabilityTransportButton(
    _ identifier: String,
    transportID: String
  ) -> String {
    "harness.window.agents.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  public static let toolCallTimeline = "harness.window.agents.tool-call-timeline"

  public static func toolCallTimelineRow(_ identifier: String) -> String {
    "\(toolCallTimeline).row.\(slug(identifier))"
  }
}
