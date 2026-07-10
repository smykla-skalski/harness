import HarnessMonitorKit
import SwiftUI

public struct SettingsConnectionSection: View {
  public let connectionState: HarnessMonitorStore.ConnectionState
  public let isDiagnosticsRefreshInFlight: Bool
  public let metrics: ConnectionMetrics
  public let events: [ConnectionEvent]
  public let remoteProfile: RemoteDaemonProfile?
  public let remoteActionState: RemoteDaemonActionState
  public let reconnect: @MainActor @Sendable () async -> Void
  public let refreshDiagnostics: @MainActor @Sendable () async -> Void
  public let pairRemoteDaemon: @MainActor @Sendable (RemoteDaemonPairingInput, String) -> Void
  public let forgetRemoteDaemon: @MainActor @Sendable () -> Void

  public init(
    connectionState: HarnessMonitorStore.ConnectionState,
    isDiagnosticsRefreshInFlight: Bool,
    metrics: ConnectionMetrics,
    events: [ConnectionEvent],
    remoteProfile: RemoteDaemonProfile?,
    remoteActionState: RemoteDaemonActionState,
    reconnect: @escaping @MainActor @Sendable () async -> Void,
    refreshDiagnostics: @escaping @MainActor @Sendable () async -> Void,
    pairRemoteDaemon:
      @escaping @MainActor @Sendable (RemoteDaemonPairingInput, String) -> Void,
    forgetRemoteDaemon: @escaping @MainActor @Sendable () -> Void
  ) {
    self.connectionState = connectionState
    self.isDiagnosticsRefreshInFlight = isDiagnosticsRefreshInFlight
    self.metrics = metrics
    self.events = events
    self.remoteProfile = remoteProfile
    self.remoteActionState = remoteActionState
    self.reconnect = reconnect
    self.refreshDiagnostics = refreshDiagnostics
    self.pairRemoteDaemon = pairRemoteDaemon
    self.forgetRemoteDaemon = forgetRemoteDaemon
  }

  public var body: some View {
    Form {
      SettingsRemoteDaemonSection(
        profile: remoteProfile,
        actionState: remoteActionState,
        pair: pairRemoteDaemon,
        forget: forgetRemoteDaemon
      )
      Section {
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
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
                "Connection Reconnect"
              ),
              action: reconnect
            )
            HarnessMonitorAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsActionButton(
                "Connection Refresh Diagnostics"
              ),
              action: refreshDiagnostics
            )
          }
        }
      } header: {
        Text("Actions")
          .harnessNativeFormSectionHeader()
      }
      SettingsConnectionMetrics(
        metrics: metrics,
        events: events
      )
    }
    .settingsDetailFormStyle()
  }
}
