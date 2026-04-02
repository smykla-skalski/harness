import HarnessKit
import SwiftUI

struct PreferencesActionButtons: View {
  let store: HarnessStore
  let isLoading: Bool
  @Binding var isRemoveLaunchAgentConfirmationPresented: Bool

  var body: some View {
    HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
      HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
        HarnessAsyncActionButton(
          title: "Reconnect",
          tint: nil,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect"),
          action: { await store.reconnect() }
        )
        HarnessAsyncActionButton(
          title: "Refresh Diagnostics",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Refresh Diagnostics"
          ),
          action: { await store.refreshDiagnostics() }
        )
        HarnessAsyncActionButton(
          title: "Start Daemon",
          tint: nil,
          variant: .prominent,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon"),
          action: { await store.startDaemon() }
        )
        HarnessAsyncActionButton(
          title: "Install Launch Agent",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Install Launch Agent"
          ),
          action: { await store.installLaunchAgent() }
        )
        HarnessActionButton(
          title: "Remove Launch Agent",
          tint: .red,
          variant: .bordered,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
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
