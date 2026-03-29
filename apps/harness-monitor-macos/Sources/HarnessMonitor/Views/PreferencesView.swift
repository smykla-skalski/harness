import HarnessMonitorKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: MonitorStore
  @Binding var themeMode: MonitorThemeMode

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
    .background(MonitorTheme.canvas)
    .foregroundStyle(MonitorTheme.ink)
    .accessibilityIdentifier(MonitorAccessibility.preferencesRoot)
    .accessibilityFrameMarker(MonitorAccessibility.preferencesPanel)
  }

  private var generalTab: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $themeMode) {
          ForEach(MonitorThemeMode.allCases) { mode in
            Text(mode.label).tag(mode)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("Daemon") {
        LabeledContent("Endpoint") {
          Text(
            effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint ?? "Unavailable"
          )
          .textSelection(.enabled)
        }
        LabeledContent("Version") {
          Text(
            effectiveHealth?.version ?? store.daemonStatus?.manifest?.version ?? "Unavailable"
          )
          .textSelection(.enabled)
        }
        LabeledContent("Launch Agent") {
          VStack(alignment: .trailing, spacing: 2) {
            Text(launchAgentState)
            Text(launchAgentCaption)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        LabeledContent("Cached Sessions") {
          Text("\(cacheEntryCount)")
        }
        generalActions
      }

      Section("Status") {
        if let startedAt = effectiveHealth?.startedAt ?? store.daemonStatus?.manifest?.startedAt {
          LabeledContent("Started") {
            Text(formatTimestamp(startedAt))
          }
        }
        if let lastError = store.lastError, !lastError.isEmpty {
          LabeledContent("Latest Error") {
            Text(lastError)
              .foregroundStyle(MonitorTheme.danger)
              .multilineTextAlignment(.trailing)
          }
        } else if !store.lastAction.isEmpty {
          LabeledContent("Last Action") {
            Text(store.lastAction)
          }
        }
      }
    }
    .formStyle(.grouped)
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
          MonitorAsyncActionButton(
            title: "Reconnect",
            tint: MonitorTheme.accent,
            variant: .prominent,
            isLoading: store.connectionState == .connecting,
            accessibilityIdentifier: MonitorAccessibility.preferencesActionButton("Reconnect")
          ) {
            await store.reconnect()
          }
          MonitorAsyncActionButton(
            title: "Refresh Diagnostics",
            tint: MonitorTheme.ink,
            variant: .bordered,
            isLoading: store.isDiagnosticsRefreshInFlight,
            accessibilityIdentifier: MonitorAccessibility.preferencesActionButton(
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
            .foregroundStyle(effectiveTokenPresent ? MonitorTheme.success : MonitorTheme.danger)
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
          MonitorAsyncActionButton(
            title: "Start Daemon",
            tint: MonitorTheme.success,
            variant: .prominent,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: MonitorAccessibility.preferencesActionButton("Start Daemon")
          ) {
            await store.startDaemon()
          }
          MonitorAsyncActionButton(
            title: "Install Launch Agent",
            tint: MonitorTheme.warmAccent,
            variant: .bordered,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: MonitorAccessibility.preferencesActionButton(
              "Install Launch Agent"
            )
          ) {
            await store.installLaunchAgent()
          }
          MonitorAsyncActionButton(
            title: "Remove Launch Agent",
            tint: MonitorTheme.danger,
            variant: .bordered,
            isLoading: store.isDaemonActionInFlight,
            accessibilityIdentifier: MonitorAccessibility.preferencesActionButton(
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

  private var generalActions: some View {
    HStack(spacing: 12) {
      MonitorAsyncActionButton(
        title: "Start Daemon",
        tint: MonitorTheme.success,
        variant: .prominent,
        isLoading: store.isDaemonActionInFlight,
        accessibilityIdentifier: MonitorAccessibility.preferencesActionButton("Start Daemon")
      ) {
        await store.startDaemon()
      }
      MonitorAsyncActionButton(
        title: "Install Launch Agent",
        tint: MonitorTheme.warmAccent,
        variant: .bordered,
        isLoading: store.isDaemonActionInFlight,
        accessibilityIdentifier: MonitorAccessibility.preferencesActionButton(
          "Install Launch Agent"
        )
      ) {
        await store.installLaunchAgent()
      }
    }
  }

  private var qualityColor: Color {
    switch store.connectionMetrics.quality {
    case .excellent, .good:
      MonitorTheme.success
    case .degraded:
      MonitorTheme.caution
    case .poor, .disconnected:
      MonitorTheme.danger
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
}
