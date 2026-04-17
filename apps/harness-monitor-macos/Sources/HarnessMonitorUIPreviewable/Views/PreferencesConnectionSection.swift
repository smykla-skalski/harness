import HarnessMonitorKit
import SwiftUI

struct PreferencesConnectionSection: View {
  let connectionState: HarnessMonitorStore.ConnectionState
  let isDiagnosticsRefreshInFlight: Bool
  let metrics: ConnectionMetrics
  let events: [ConnectionEvent]
  let reconnect: @MainActor @Sendable () async -> Void
  let refreshDiagnostics: @MainActor @Sendable () async -> Void

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
              isLoading: connectionState == .connecting,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
                "Connection Reconnect"
              ),
              action: reconnect
            )
            HarnessMonitorAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessMonitorAccessibility.preferencesActionButton(
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
    connectionState: store.connectionState,
    isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
    metrics: store.connectionMetrics,
    events: store.connectionEvents,
    reconnect: { await store.reconnect() },
    refreshDiagnostics: { await store.refreshDiagnostics() }
  )
  .frame(width: 720)
}
