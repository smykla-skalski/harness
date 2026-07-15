import HarnessMonitorKit
import SwiftUI

struct SettingsActionButtons: View {
  let availability: SettingsDaemonActionAvailability
  let isLoading: Bool
  @Binding var isRemoveLaunchAgentConfirmationPresented: Bool
  let reconnect: @MainActor @Sendable () async -> Void
  let refreshDiagnostics: @MainActor @Sendable () async -> Void
  let startDaemon: @MainActor @Sendable () async -> Void
  let installLaunchAgent: @MainActor @Sendable () async -> Void

  private static let externalDaemonCommand = "harness-daemon dev"

  var body: some View {
    HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
      HarnessMonitorWrapLayout(
        spacing: HarnessMonitorTheme.itemSpacing,
        lineSpacing: HarnessMonitorTheme.itemSpacing
      ) {
        HarnessMonitorAsyncActionButton(
          title: "Reconnect",
          tint: nil,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton("Reconnect"),
          action: reconnect
        )
        HarnessMonitorAsyncActionButton(
          title: "Refresh Diagnostics",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
            "Refresh Diagnostics"
          ),
          action: refreshDiagnostics
        )
        if availability.showsManagedControls {
          HarnessMonitorAsyncActionButton(
            title: "Start Daemon",
            tint: nil,
            variant: .prominent,
            isLoading: isLoading,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
              "Start Daemon"
            ),
            action: startDaemon
          )
          HarnessMonitorAsyncActionButton(
            title: "Install Launch Agent",
            tint: .secondary,
            variant: .bordered,
            isLoading: isLoading,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
              "Install Launch Agent"
            ),
            action: installLaunchAgent
          )
          HarnessMonitorActionButton(
            title: "Remove Launch Agent",
            tint: .red,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
              "Remove Launch Agent"
            )
          ) {
            isRemoveLaunchAgentConfirmationPresented = true
          }
        } else if availability.showsExternalDevCommand {
          HarnessMonitorActionButton(
            title: "Copy Dev Command",
            tint: .secondary,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
              "Copy Dev Command"
            )
          ) {
            copyExternalDaemonCommandToClipboard()
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func copyExternalDaemonCommandToClipboard() {
    HarnessMonitorClipboard.copy(Self.externalDaemonCommand)
  }
}
