import SwiftUI

extension HarnessMonitorAccessibility {
  public static let contentAcpBridgeBanner = "harness.content.acp-bridge.banner"
  public static let contentAcpBridgeOpenLogButton = "harness.content.acp-bridge.open-log"
  public static let contentAcpBridgeRunDoctorButton = "harness.content.acp-bridge.run-doctor"

  public static let settingsAcpNotificationStatus = "harness.settings.acp.status"
  public static let settingsAcpNotificationStatusState = "harness.settings.acp.status.state"
  public static let settingsAcpCatalogToggle = "harness.settings.acp.catalog.toggle"
  public static let settingsAcpCatalogPermission = "harness.settings.acp.catalog.permission"
  public static let settingsAcpVerboseAnnounceToggle =
    "harness.settings.acp.verbose-tool-call-announcements"
  public static let settingsAcpOpenSystemSettings =
    "harness.settings.acp.open-system-settings"

  public static let acpPermissionToast = "harness.acp-permission.toast"
  public static let acpPermissionToastFrame = "harness.acp-permission.toast.frame"
  public static let acpPermissionToastState = "harness.acp-permission.toast.state"
  public static let acpPermissionToastAccessibilityState =
    "harness.acp-permission.toast.accessibility.state"
  public static let toolCallTimelineAccessibilityState =
    "harness.timeline.tool-call.accessibility.state"
  public static let agentRuntimeWatchdogAccessibilityState =
    "harness.agent.detail.runtime.watchdog.accessibility.state"
  public static let acpPermissionToastRouteState = "harness.acp-permission.toast.route.state"
  public static let acpPermissionToastActionButton =
    "harness.acp-permission.toast.open-decisions"
  public static let acpPermissionToastCloseButton = "harness.acp-permission.toast.close"

  public static func agentCapabilityRow(_ identifier: String) -> String {
    "harness.agent.capability.\(slug(identifier))"
  }

  public static func agentCapabilityInstallButton(_ identifier: String) -> String {
    "harness.agent.capability.\(slug(identifier)).install"
  }

  public static func agentCapabilityProbe(_ identifier: String) -> String {
    "harness.agent.capability.\(slug(identifier)).probe"
  }

  public static func agentCapabilityTransportButton(
    _ identifier: String,
    transportID: String
  ) -> String {
    "harness.agent.capability.\(slug(identifier)).transport.\(slug(transportID))"
  }

  public static let toolCallTimeline = "harness.timeline.tool-call"

  public static func toolCallTimelineRow(_ identifier: String) -> String {
    "\(toolCallTimeline).row.\(slug(identifier))"
  }
}
