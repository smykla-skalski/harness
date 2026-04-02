import HarnessKit
import SwiftUI

struct PreferencesActionButtons: View {
  let isLoading: Bool
  let reconnect: HarnessAsyncActionButton.Action
  let refreshDiagnostics: HarnessAsyncActionButton.Action
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let removeLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
      HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
        HarnessAsyncActionButton(
          title: "Reconnect",
          tint: nil,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect"),
          action: reconnect
        )
        HarnessAsyncActionButton(
          title: "Refresh Diagnostics",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Refresh Diagnostics"
          ),
          action: refreshDiagnostics
        )
        HarnessAsyncActionButton(
          title: "Start Daemon",
          tint: nil,
          variant: .prominent,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon"),
          action: startDaemon
        )
        HarnessAsyncActionButton(
          title: "Install Launch Agent",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Install Launch Agent"
          ),
          action: installLaunchAgent
        )
        HarnessAsyncActionButton(
          title: "Remove Launch Agent",
          tint: .red,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Remove Launch Agent"
          ),
          action: removeLaunchAgent
        )
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

#Preview("Preferences Actions") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    Section("Actions") {
      PreferencesActionButtons(
        isLoading: false,
        reconnect: { await store.reconnect() },
        refreshDiagnostics: { await store.refreshDiagnostics() },
        startDaemon: { await store.startDaemon() },
        installLaunchAgent: { await store.installLaunchAgent() },
        removeLaunchAgent: { store.requestRemoveLaunchAgentConfirmation() }
      )
    }
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}
