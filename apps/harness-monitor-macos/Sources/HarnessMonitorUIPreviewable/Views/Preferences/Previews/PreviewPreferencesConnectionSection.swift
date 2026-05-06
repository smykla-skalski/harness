import HarnessMonitorKit
import SwiftUI

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
