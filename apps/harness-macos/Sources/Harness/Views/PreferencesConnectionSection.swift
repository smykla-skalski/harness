import HarnessKit
import SwiftUI

struct PreferencesConnectionSection: View {
  let isConnecting: Bool
  let isDiagnosticsRefreshInFlight: Bool
  let reconnect: HarnessAsyncActionButton.Action
  let refreshDiagnostics: HarnessAsyncActionButton.Action
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]

  var body: some View {
    Form {
      Section("Actions") {
        HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
          HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
            HarnessAsyncActionButton(
              title: "Reconnect",
              tint: nil,
              variant: .prominent,
              isLoading: isConnecting,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Reconnect"
              ),
              action: reconnect
            )
            HarnessAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Refresh Diagnostics"
              ),
              action: refreshDiagnostics
            )
          }
        }
      }
      PreferencesConnectionMetrics(
        metrics: metrics,
        events: events
      )
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences Connection Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesConnectionSection(
    isConnecting: store.connectionState == .connecting,
    isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
    reconnect: { await store.reconnect() },
    refreshDiagnostics: { await store.refreshDiagnostics() },
    metrics: store.connectionMetrics,
    events: store.connectionEvents
  )
  .frame(width: 720)
}
