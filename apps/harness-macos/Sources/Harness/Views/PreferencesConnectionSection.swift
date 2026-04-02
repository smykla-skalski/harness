import HarnessKit
import SwiftUI

struct PreferencesConnectionSection: View {
  let store: HarnessStore

  var body: some View {
    Form {
      Section("Actions") {
        HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
          HarnessWrapLayout(
            spacing: HarnessTheme.itemSpacing,
            lineSpacing: HarnessTheme.itemSpacing
          ) {
            HarnessAsyncActionButton(
              title: "Reconnect",
              tint: nil,
              variant: .prominent,
              isLoading: store.connectionState == .connecting,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Reconnect"
              ),
              action: { await store.reconnect() }
            )
            HarnessAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: store.isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Refresh Diagnostics"
              ),
              action: { await store.refreshDiagnostics() }
            )
          }
        }
      }
      PreferencesConnectionMetrics(
        metrics: store.connectionMetrics,
        events: store.connectionEvents
      )
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences Connection Section") {
  PreferencesConnectionSection(
    store: PreferencesPreviewSupport.makeStore()
  )
  .frame(width: 720)
}
