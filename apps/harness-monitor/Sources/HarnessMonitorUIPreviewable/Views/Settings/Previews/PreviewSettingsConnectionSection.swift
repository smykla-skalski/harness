import HarnessMonitorKit
import SwiftUI

#Preview("Settings Connection Section") {
  let store = SettingsPreviewSupport.makeStore()

  SettingsConnectionSection(
    connectionState: store.connectionState,
    isDiagnosticsRefreshInFlight: store.isDiagnosticsRefreshInFlight,
    metrics: store.connectionMetrics,
    events: store.connectionEvents,
    remoteProfile: store.remoteDaemonProfile,
    remoteActionState: store.remoteDaemonActionState,
    reconnect: { await store.reconnect() },
    refreshDiagnostics: { await store.refreshDiagnostics() },
    pairRemoteDaemon: { _, _ in },
    forgetRemoteDaemon: {}
  )
  .frame(width: 720)
}
