import AppKit
import HarnessMonitorKit
import SwiftUI

struct PreferencesActionButtons: View {
  let store: HarnessMonitorStore
  let isLoading: Bool
  @Binding var isRemoveLaunchAgentConfirmationPresented: Bool

  private static let externalDaemonCommand = "harness daemon dev"

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
          accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton("Reconnect"),
          action: { await store.reconnect() }
        )
        HarnessMonitorAsyncActionButton(
          title: "Refresh Diagnostics",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
            "Refresh Diagnostics"
          ),
          action: { await store.refreshDiagnostics() }
        )
        if store.daemonOwnership == .managed {
          HarnessMonitorAsyncActionButton(
            title: "Start Daemon",
            tint: nil,
            variant: .prominent,
            isLoading: isLoading,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Start Daemon"
            ),
            action: { await store.startDaemon() }
          )
          HarnessMonitorAsyncActionButton(
            title: "Install Launch Agent",
            tint: .secondary,
            variant: .bordered,
            isLoading: isLoading,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Install Launch Agent"
            ),
            action: { await store.installLaunchAgent() }
          )
          HarnessMonitorActionButton(
            title: "Remove Launch Agent",
            tint: .red,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
              "Remove Launch Agent"
            )
          ) {
            isRemoveLaunchAgentConfirmationPresented = true
          }
        } else {
          HarnessMonitorActionButton(
            title: "Copy Dev Command",
            tint: .secondary,
            variant: .bordered,
            accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
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
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(Self.externalDaemonCommand, forType: .string)
  }
}

#Preview("Preferences Actions") {
  @Previewable @State var isConfirmationPresented = false

  Form {
    Section("Actions") {
      PreferencesActionButtons(
        store: PreferencesPreviewSupport.makeStore(),
        isLoading: false,
        isRemoveLaunchAgentConfirmationPresented: $isConfirmationPresented
      )
    }
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
