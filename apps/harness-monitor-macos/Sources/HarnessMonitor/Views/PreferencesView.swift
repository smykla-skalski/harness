import HarnessMonitorKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: MonitorStore

  private var effectiveHealth: HealthResponse? {
    store.diagnostics?.health ?? store.health
  }

  private var cacheEntryCount: Int {
    store.diagnostics?.workspace.cacheEntryCount
      ?? store.daemonStatus?.diagnostics.cacheEntryCount
      ?? 0
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(alignment: .leading, spacing: 18) {
        header
        overviewRow
        pathsCard
        diagnosticsCard
        recentEventsCard
        footer
      }
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MonitorTheme.canvas)
    .foregroundStyle(MonitorTheme.ink)
    .accessibilityIdentifier(MonitorAccessibility.preferencesRoot)
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
        statePill
      }

      HStack(spacing: 12) {
        actionButton("Reconnect", tint: MonitorTheme.accent) {
          await store.reconnect()
        }
        actionButton("Refresh Diagnostics", tint: MonitorTheme.ink) {
          await store.refreshDiagnostics()
        }
        actionButton("Start Daemon", tint: MonitorTheme.success) {
          await store.startDaemon()
        }
        actionButton("Install Launch Agent", tint: MonitorTheme.warmAccent) {
          await store.installLaunchAgent()
        }
        actionButton("Remove Launch Agent", tint: MonitorTheme.danger) {
          await store.removeLaunchAgent()
        }
      }
    }
    .monitorCard()
  }

  private var overviewRow: some View {
    HStack(alignment: .top, spacing: 14) {
      overviewMetric(
        title: "Endpoint",
        value: effectiveHealth?.endpoint ?? store.daemonStatus?.manifest?.endpoint ?? "Unavailable",
        caption: "Local control plane"
      )
      overviewMetric(
        title: "Version",
        value: effectiveHealth?.version ?? store.daemonStatus?.manifest?.version ?? "Unavailable",
        caption: "Daemon build"
      )
      overviewMetric(
        title: "Launchd",
        value: launchAgentState,
        caption: store.daemonStatus?.launchAgent.label ?? "Launch agent"
      )
      overviewMetric(
        title: "Cached Sessions",
        value: "\(cacheEntryCount)",
        caption: "\(store.daemonStatus?.sessionCount ?? 0) indexed live sessions"
      )
    }
  }

  private var pathsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Paths")
        .font(.system(.title3, design: .serif, weight: .semibold))
      pathRow(
        title: "Launch Agent",
        value: store.daemonStatus?.launchAgent.path ?? "Unavailable"
      )
      pathRow(
        title: "Manifest",
        value: store.diagnostics?.workspace.manifestPath
          ?? store.daemonStatus?.diagnostics.manifestPath
          ?? "Unavailable"
      )
      pathRow(
        title: "Auth Token",
        value: store.diagnostics?.workspace.authTokenPath
          ?? store.daemonStatus?.diagnostics.authTokenPath
          ?? "Unavailable"
      )
      pathRow(
        title: "Events Log",
        value: store.diagnostics?.workspace.eventsPath
          ?? store.daemonStatus?.diagnostics.eventsPath
          ?? "Unavailable"
      )
      pathRow(
        title: "Cache Root",
        value: store.diagnostics?.workspace.cacheRoot
          ?? store.daemonStatus?.diagnostics.cacheRoot
          ?? "Unavailable"
      )
    }
    .monitorCard()
  }

  private var diagnosticsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Diagnostics")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HStack(alignment: .top, spacing: 14) {
        diagnosticBadge(
          title: "Token",
          value: effectiveTokenPresent ? "Present" : "Missing",
          tint: effectiveTokenPresent
            ? MonitorTheme.success : MonitorTheme.danger
        )
        diagnosticBadge(
          title: "Projects",
          value: "\(store.daemonStatus?.projectCount ?? 0)",
          tint: MonitorTheme.accent
        )
        diagnosticBadge(
          title: "Sessions",
          value: "\(store.daemonStatus?.sessionCount ?? 0)",
          tint: MonitorTheme.warmAccent
        )
      }

      if let lastEvent = effectiveLastEvent {
        VStack(alignment: .leading, spacing: 8) {
          Text("Latest Event")
            .font(.headline)
          Text(lastEvent.message)
            .font(.system(.body, design: .rounded, weight: .semibold))
          Text("\(lastEvent.level.uppercased()) • \(formatTimestamp(lastEvent.recordedAt))")
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
      } else {
        Text("No daemon audit events have been recorded yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
      }
    }
    .monitorCard()
  }

  private var recentEventsCard: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Recent Events")
        .font(.system(.title3, design: .serif, weight: .semibold))

      if (store.diagnostics?.recentEvents ?? []).isEmpty {
        Text("No daemon events available from the live diagnostics stream yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.diagnostics?.recentEvents ?? []) { event in
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text(event.level.uppercased())
                .font(.caption.bold())
                .foregroundStyle(event.level == "warn" ? MonitorTheme.caution : MonitorTheme.accent)
              Spacer()
              Text(formatTimestamp(event.recordedAt))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            }
            Text(event.message)
              .font(.system(.body, design: .rounded, weight: .semibold))
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
        }
      }
    }
    .monitorCard()
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

  private func actionButton(
    _ title: String,
    tint: Color,
    action: @escaping @Sendable () async -> Void
  ) -> some View {
    Button(title) {
      Task {
        await action()
      }
    }
    .buttonStyle(.borderedProminent)
    .tint(tint)
  }

  private func overviewMetric(title: String, value: String, caption: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .textSelection(.enabled)
      Text(caption)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard()
  }

  private func pathRow(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
  }

  private func diagnosticBadge(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .bold))
        .foregroundStyle(tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
  }
}
