import HarnessMonitorKit
import SwiftUI

struct PreferencesConnectionSection: View {
  let store: HarnessMonitorStore

  var body: some View {
    Form {
      Section("Actions") {
        HarnessMonitorGlassControlGroup(spacing: HarnessMonitorTheme.itemSpacing) {
          HarnessMonitorWrapLayout(
            spacing: HarnessMonitorTheme.itemSpacing,
            lineSpacing: HarnessMonitorTheme.itemSpacing
          ) {
            HarnessMonitorAsyncActionButton(
              title: "Reconnect",
              tint: nil,
              variant: .prominent,
              isLoading: store.connectionState == .connecting,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
                "Connection Reconnect"
              ),
              action: { await store.reconnect() }
            )
            HarnessMonitorAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: store.isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
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
