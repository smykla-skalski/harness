import HarnessKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: HarnessStore
  @Binding var themeMode: HarnessThemeMode

  private var effectiveHealth: HealthResponse? {
    store.diagnostics?.health ?? store.health
  }

  private var cacheEntryCount: Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount
      ?? 0
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
    store.daemonStatus?.launchAgent.lifecycleTitle ?? "Manual"
  }

  private var launchAgentCaption: String {
    let fallback = store.daemonStatus?.launchAgent.label ?? "Launch agent"
    let caption = store.daemonStatus?.launchAgent.lifecycleCaption ?? fallback
    return caption.isEmpty ? fallback : caption
  }

  private var generalActionsAreLoading: Bool {
    store.isDaemonActionInFlight
      || store.isDiagnosticsRefreshInFlight
      || store.connectionState == .connecting
  }

  var body: some View {
    TabView {
      generalTab
        .tabItem {
          Label("General", systemImage: "gearshape")
        }

      connectionTab
        .tabItem {
          Label("Connection", systemImage: "bolt.horizontal.circle")
        }

      diagnosticsTab
        .tabItem {
          Label("Diagnostics", systemImage: "stethoscope")
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HarnessTheme.canvas)
    .foregroundStyle(HarnessTheme.ink)
    .accessibilityIdentifier(HarnessAccessibility.preferencesRoot)
    .accessibilityFrameMarker(HarnessAccessibility.preferencesPanel)
  }

  private var generalTab: some View {
    HarnessColumnScrollView(horizontalPadding: 20, verticalPadding: 20) {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 14) {
          Text("Appearance")
            .font(.system(.title3, design: .serif, weight: .semibold))
          Picker("Theme", selection: $themeMode) {
            ForEach(HarnessThemeMode.allCases) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }
        .harnessCard()

        PreferencesActionGrid(
          isLoading: generalActionsAreLoading,
          reconnect: { await store.reconnect() },
          refreshDiagnostics: { await store.refreshDiagnostics() },
          startDaemon: { await store.startDaemon() },
          installLaunchAgent: { await store.installLaunchAgent() },
          requestRemoveLaunchAgentConfirmation: { store.requestRemoveLaunchAgentConfirmation() }
        )

        PreferencesOverviewGrid(
          endpoint: effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint
            ?? "Unavailable",
          version: effectiveHealth?.version ?? store.daemonStatus?.manifest?.version
            ?? "Unavailable",
          launchAgentState: launchAgentState,
          launchAgentCaption: launchAgentCaption,
          cacheEntryCount: cacheEntryCount,
          sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count
        )

        VStack(alignment: .leading, spacing: 14) {
          Text("Status")
            .font(.system(.title3, design: .serif, weight: .semibold))

          if let startedAt = effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt {
            statusRow(title: "Started", value: formatTimestamp(startedAt))
          }

          if let lastError = store.lastError, !lastError.isEmpty {
            statusRow(title: "Latest Error", value: lastError, valueColor: HarnessTheme.danger)
          } else if !store.lastAction.isEmpty {
            statusRow(title: "Last Action", value: store.lastAction)
          } else {
            Text("No recent daemon actions yet.")
              .font(.system(.body, design: .rounded, weight: .medium))
              .foregroundStyle(HarnessTheme.secondaryInk)
          }
        }
        .harnessCard()
      }
    }
  }

  private var connectionTab: some View {
    Form {
      Section("Transport") {
        LabeledContent("Mode") {
          Text(store.connectionMetrics.transportKind.title)
        }
        LabeledContent("Quality") {
          Text(store.connectionMetrics.quality.title)
            .foregroundStyle(qualityColor)
        }
        LabeledContent("Latency") {
          Text(store.connectionMetrics.latencyMs.map { "\($0) ms" } ?? "Unavailable")
        }
        LabeledContent("Average Latency") {
          Text(store.connectionMetrics.averageLatencyMs.map { "\($0) ms" } ?? "Unavailable")
        }
        LabeledContent("Connected Since") {
          Text(store.connectionMetrics.connectedSince.map(connectionTimestamp) ?? "Unavailable")
        }
      }

      Section("Traffic") {
        LabeledContent("Messages Received") {
          Text("\(store.connectionMetrics.messagesReceived)")
        }
        LabeledContent("Messages Sent") {
          Text("\(store.connectionMetrics.messagesSent)")
        }
        LabeledContent("Throughput") {
          Text(throughputText)
        }
      }

      Section("Actions") {
        HStack(spacing: 12) {
          HarnessAsyncActionButton(
            title: "Reconnect",
            tint: HarnessTheme.accent,
            variant: .prominent,
            isLoading: store.connectionState == .connecting,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect")
          ) {
            await store.reconnect()
          }
          HarnessAsyncActionButton(
            title: "Refresh Diagnostics",
            tint: HarnessTheme.ink,
            variant: .bordered,
            isLoading: store.isDiagnosticsRefreshInFlight,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Refresh Diagnostics"
            )
          ) {
            await store.refreshDiagnostics()
          }
        }
      }

      if !store.connectionEvents.isEmpty {
        Section("Recent Connection Events") {
          ForEach(store.connectionEvents.reversed().prefix(10)) { event in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(event.kind.title)
                  .font(.headline)
                Spacer()
                Text(connectionTimestamp(event.timestamp))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Text(event.detail)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var diagnosticsTab: some View {
    Form {
      Section("Workspace") {
        LabeledContent("Token") {
          Text(effectiveTokenPresent ? "Present" : "Missing")
            .foregroundStyle(effectiveTokenPresent ? HarnessTheme.success : HarnessTheme.danger)
        }
        LabeledContent("Projects") {
          Text("\(store.daemonStatus?.projectCount ?? 0)")
        }
        LabeledContent("Sessions") {
          Text("\(store.daemonStatus?.sessionCount ?? 0)")
        }
        if let lastEvent = effectiveLastEvent {
          LabeledContent("Latest Event") {
            VStack(alignment: .trailing, spacing: 2) {
              Text(lastEvent.message)
                .multilineTextAlignment(.trailing)
              Text(
                "\(lastEvent.level.uppercased()) • \(formatTimestamp(lastEvent.recordedAt))"
              )
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section("Paths") {
        pathRow("Launch Agent", value: store.daemonStatus?.launchAgent.path)
        pathRow(
          "Manifest",
          value: store.diagnostics?.workspace.manifestPath
            ?? store.daemonStatus?.diagnostics.manifestPath
        )
        pathRow(
          "Auth Token",
          value: store.diagnostics?.workspace.authTokenPath
            ?? store.daemonStatus?.diagnostics.authTokenPath
        )
        pathRow(
          "Events Log",
          value: store.diagnostics?.workspace.eventsPath
            ?? store.daemonStatus?.diagnostics.eventsPath
        )
        pathRow(
          "Cache Root",
          value: store.diagnostics?.workspace.cacheRoot
            ?? store.daemonStatus?.diagnostics.cacheRoot
        )
      }

      Section("Daemon Actions") {
        HStack(spacing: 12) {
          HarnessAsyncActionButton(
            title: "Start Daemon",
            tint: HarnessTheme.success,
            variant: .prominent,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon")
          ) {
            await store.startDaemon()
          }
          HarnessAsyncActionButton(
            title: "Install Launch Agent",
            tint: HarnessTheme.warmAccent,
            variant: .bordered,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Install Launch Agent"
            )
          ) {
            await store.installLaunchAgent()
          }
          HarnessAsyncActionButton(
            title: "Remove Launch Agent",
            tint: HarnessTheme.danger,
            variant: .bordered,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Remove Launch Agent"
            )
          ) {
            await store.removeLaunchAgent()
          }
        }
      }

      if let diagnostics = store.diagnostics, !diagnostics.recentEvents.isEmpty {
        Section("Recent Daemon Events") {
          ForEach(diagnostics.recentEvents.prefix(10)) { event in
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(event.level.uppercased())
                  .font(.headline)
                Spacer()
                Text(formatTimestamp(event.recordedAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Text(event.message)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
          }
        }
      }
    }
    .formStyle(.grouped)
  }

  private var qualityColor: Color {
    switch store.connectionMetrics.quality {
    case .excellent, .good:
      HarnessTheme.success
    case .degraded:
      HarnessTheme.caution
    case .poor, .disconnected:
      HarnessTheme.danger
    }
  }

  private var throughputText: String {
    guard store.connectionMetrics.messagesPerSecond != 0 else {
      return "Idle"
    }
    let formattedRate = store.connectionMetrics.messagesPerSecond.formatted(
      .number.precision(.fractionLength(1))
    )
    return "\(formattedRate) msg/s"
  }

  @ViewBuilder
  private func pathRow(_ title: String, value: String?) -> some View {
    LabeledContent(title) {
      Text(value ?? "Unavailable")
        .font(.body.monospaced())
        .textSelection(.enabled)
    }
  }

  private func connectionTimestamp(_ value: Date) -> String {
    value.formatted(date: .abbreviated, time: .standard)
  }

  private func statusRow(
    title: String,
    value: String,
    valueColor: Color = HarnessTheme.ink
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(valueColor)
        .multilineTextAlignment(.leading)
        .textSelection(.enabled)
    }
  }
}
