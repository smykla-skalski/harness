import HarnessMonitorKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: MonitorStore
  @Binding var themeMode: MonitorThemeMode
  let onDismiss: (() -> Void)?

  init(
    store: MonitorStore,
    themeMode: Binding<MonitorThemeMode> = .constant(.auto),
    onDismiss: (() -> Void)? = nil
  ) {
    self.store = store
    _themeMode = themeMode
    self.onDismiss = onDismiss
  }

  private var effectiveHealth: HealthResponse? {
    store.diagnostics?.health ?? store.health
  }

  private var cacheEntryCount: Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount
      ?? 0
  }

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  private var effectiveLastEvent: DaemonAuditEvent? {
    store.diagnostics?.workspace.lastEvent ?? store.daemonStatus?.diagnostics.lastEvent
  }

  private var effectiveTokenPresent: Bool {
    store.diagnostics?.workspace.authTokenPresent
      ?? store.daemonStatus?.diagnostics.authTokenPresent
      ?? false
  }

  private var launchAgentState: String {
    store.daemonStatus?.launchAgent.installed == true ? "Installed" : "Manual"
  }

  var body: some View {
    MonitorColumnScrollView(horizontalPadding: 24, verticalPadding: 24) {
      VStack(alignment: .leading, spacing: 18) {
        header
        PreferencesOverviewGrid(
          endpoint: effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint
            ?? "Unavailable",
          version: effectiveHealth?.version ?? store.daemonStatus?.manifest?.version
            ?? "Unavailable",
          launchAgentState: launchAgentState,
          launchAgentCaption: store.daemonStatus?.launchAgent.label ?? "Launch agent",
          cacheEntryCount: cacheEntryCount,
          sessionCount: store.daemonStatus?.sessionCount ?? 0
        )
        PreferencesPathsCard(
          launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
          manifestPath: store.diagnostics?.workspace.manifestPath
            ?? store.daemonStatus?.diagnostics.manifestPath
            ?? "Unavailable",
          authTokenPath: store.diagnostics?.workspace.authTokenPath
            ?? store.daemonStatus?.diagnostics.authTokenPath
            ?? "Unavailable",
          eventsPath: store.diagnostics?.workspace.eventsPath
            ?? store.daemonStatus?.diagnostics.eventsPath
            ?? "Unavailable",
          cacheRoot: store.diagnostics?.workspace.cacheRoot
            ?? store.daemonStatus?.diagnostics.cacheRoot
            ?? "Unavailable"
        )
        PreferencesDiagnosticsCard(
          tokenPresent: effectiveTokenPresent,
          projectCount: store.daemonStatus?.projectCount ?? 0,
          sessionCount: store.daemonStatus?.sessionCount ?? 0,
          lastEvent: effectiveLastEvent
        )
        PreferencesRecentEventsCard(events: store.diagnostics?.recentEvents ?? [])
        footer
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MonitorTheme.canvas)
    .foregroundStyle(MonitorTheme.ink)
    .task {
      await store.refreshDiagnostics()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Daemon Preferences")
            .font(.system(.largeTitle, design: .serif, weight: .bold))
          Text(
            "The monitor only reads live session state from the local harness daemon. "
              + "Use this panel to validate residency, launchd persistence, auth token presence, "
              + "and local cache health."
          )
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
        }
        Spacer()
        HStack(spacing: 10) {
          statePill
          if let onDismiss {
            Button(action: onDismiss) {
              Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .frame(width: 32, height: 32)
                .background(MonitorTheme.surfaceHover, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(MonitorAccessibility.preferencesCloseButton)
          }
        }
      }

      if isLoading {
        MonitorLoadingStateView(title: loadingTitle)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      VStack(alignment: .leading, spacing: 8) {
        Text("Appearance")
          .font(.caption.weight(.bold))
          .foregroundStyle(.secondary)
        Picker("Appearance", selection: $themeMode) {
          ForEach(MonitorThemeMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }

      PreferencesActionGrid(
        isLoading: isLoading,
        reconnect: store.reconnect,
        refreshDiagnostics: store.refreshDiagnostics,
        startDaemon: store.startDaemon,
        installLaunchAgent: store.installLaunchAgent,
        requestRemoveLaunchAgentConfirmation: store.requestRemoveLaunchAgentConfirmation
      )
    }
    .monitorCard(contentPadding: 16)
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let startedAt = effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt {
        Text("Started \(formatTimestamp(startedAt))")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      if let lastError = store.lastError, !lastError.isEmpty {
        Text(lastError)
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(MonitorTheme.danger)
      } else if !store.lastAction.isEmpty {
        Text("Last action: \(store.lastAction)")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var loadingTitle: String {
    if store.connectionState == .connecting {
      return "Connecting to the daemon bridge"
    }
    if store.isRefreshing {
      return "Refreshing live diagnostics"
    }
    return "Submitting daemon action"
  }

  private var statePill: some View {
    Text(store.connectionState == .online ? "Live" : "Needs Attention")
      .font(.caption.bold())
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(
        store.connectionState == .online ? MonitorTheme.success : MonitorTheme.caution,
        in: Capsule()
      )
      .foregroundStyle(.white)
  }
}
