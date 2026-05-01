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
    "harness.window.workspace.tool-call-timeline.accessibility.state"
  public static let agentRuntimeWatchdogAccessibilityState =
    "harness.workspace.detail.runtime.watchdog.accessibility.state"
  public static let acpPermissionToastRouteState = "harness.acp-permission.toast.route.state"
  public static let acpPermissionToastActionButton =
    "harness.acp-permission.toast.open-workspace"
  public static let acpPermissionToastCloseButton = "harness.acp-permission.toast.close"

  public static let workspaceCodexModelPicker = "harness.window.workspace.codex.model"
  public static let workspaceCodexCustomModelField = "harness.window.workspace.codex.model.custom"
  public static let workspaceCodexEffortPicker = "harness.window.workspace.codex.effort"
  public static let workspaceCodexPromptField = "harness.window.workspace.codex.prompt"
  public static let workspaceCodexContextField = "harness.window.workspace.codex.context"
  public static let workspaceCodexModePicker = "harness.window.workspace.codex.mode"
  public static let workspaceCodexSubmitButton = "harness.window.workspace.codex.submit"
  public static let workspaceCodexSteerButton = "harness.window.workspace.codex.steer"
  public static let workspaceCodexInterruptButton = "harness.window.workspace.codex.interrupt"
  public static let workspaceCodexFinalMessage = "harness.window.workspace.codex.final"
  public static let workspaceCodexLatestSummary = "harness.window.workspace.codex.latest"
  public static let workspaceCodexErrorMessage = "harness.window.workspace.codex.error"
  public static let workspaceCodexRecoveryBanner =
    "harness.window.workspace.codex.recovery-banner"
  public static let workspaceCodexEnableBridgeButton =
    "harness.window.workspace.codex.enable-bridge"
  public static let workspaceCodexCopyCommandButton =
    "harness.window.workspace.codex.copy-command"
  public static let workspaceAcpRecoveryBanner = "harness.window.workspace.acp.recovery-banner"
  public static let workspaceAcpEnableBridgeButton = "harness.window.workspace.acp.enable-bridge"
  public static let workspaceAcpCopyCommandButton = "harness.window.workspace.acp.copy-command"

  public static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier))"
  }

  public static func agentCapabilityInstallButton(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).install"
  }

  public static func agentCapabilityProbe(_ identifier: String) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).probe"
  }

  public static func agentCapabilityTransportButton(
    _ identifier: String,
    transportID: String
  ) -> String {
    "harness.window.workspace.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  public static let workspaceToolCallTimeline = "harness.window.workspace.tool-call-timeline"

  public static func toolCallTimelineRow(_ identifier: String) -> String {
    "\(workspaceToolCallTimeline).row.\(slug(identifier))"
  }
}
