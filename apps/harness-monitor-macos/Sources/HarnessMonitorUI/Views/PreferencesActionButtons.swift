import HarnessMonitorKit
import SwiftUI

struct PreferencesActionButtons: View {
  let store: HarnessMonitorStore
  let isLoading: Bool
  @Binding var isRemoveLaunchAgentConfirmationPresented: Bool

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
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
