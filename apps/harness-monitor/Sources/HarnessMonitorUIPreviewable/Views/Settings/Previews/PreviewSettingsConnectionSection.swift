import HarnessMonitorKit
import SwiftUI

#Preview("Settings Connection Section") {
  let store = SettingsPreviewSupport.makeStore()

  SettingsConnectionSection(
    connectionState: store.connectionState,
    isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
    metrics: store.connectionMetrics,
    events: store.connectionEvents,
    reconnect: { await store.reconnect() },
    refreshDiagnostics: { await store.refreshDiagnostics() }
  )
  .frame(width: 720)
}
