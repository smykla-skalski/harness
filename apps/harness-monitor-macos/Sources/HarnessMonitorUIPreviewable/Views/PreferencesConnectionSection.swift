import HarnessMonitorKit
import SwiftUI

public struct PreferencesConnectionSection: View {
  public let connectionState: HarnessMonitorStore.ConnectionState
  public let isDiagnosticsRefreshInFlight: Bool
  public let metrics: ConnectionMetrics
  public let events: [ConnectionEvent]
  public let reconnect: @MainActor @Sendable () async -> Void
  public let refreshDiagnostics: @MainActor @Sendable () async -> Void

  public init(
    connectionState: HarnessMonitorStore.ConnectionState,
    isDiagnosticsRefreshInFlight: Bool,
    metrics: ConnectionMetrics,
    events: [ConnectionEvent],
    reconnect: @escaping @MainActor @Sendable () async -> Void,
    refreshDiagnostics: @escaping @MainActor @Sendable () async -> Void
  ) {
    self.connectionState = connectionState
    self.isDiagnosticsRefreshInFlight = isDiagnosticsRefreshInFlight
    self.metrics = metrics
    self.events = events
    self.reconnect = reconnect
    self.refreshDiagnostics = refreshDiagnostics
  }

  public var body: some View {
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
