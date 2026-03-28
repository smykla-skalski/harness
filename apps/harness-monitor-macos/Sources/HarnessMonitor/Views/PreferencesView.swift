import HarnessMonitorKit
import Observation
import SwiftUI

struct PreferencesView: View {
  @Bindable var store: MonitorStore

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        overviewRow
        pathsCard
        diagnosticsCard
        footer
      }
      .padding(24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(MonitorTheme.canvas.ignoresSafeArea())
    .foregroundStyle(MonitorTheme.ink)
    .accessibilityIdentifier(MonitorAccessibility.preferencesRoot)
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
          await store.refreshDaemonStatus()
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
        value: store.health?.endpoint ?? store.daemonStatus?.manifest?.endpoint ?? "Unavailable",
        caption: "Local control plane"
      )
      overviewMetric(
        title: "Version",
        value: store.health?.version ?? store.daemonStatus?.manifest?.version ?? "Unavailable",
        caption: "Daemon build"
      )
      overviewMetric(
        title: "Launchd",
        value: store.daemonStatus?.launchAgent.installed == true ? "Installed" : "Manual",
        caption: store.daemonStatus?.launchAgent.label ?? "Launch agent"
      )
      overviewMetric(
        title: "Cached Sessions",
        value: "\(store.daemonStatus?.diagnostics.cacheEntryCount ?? 0)",
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
        value: store.daemonStatus?.diagnostics.manifestPath ?? "Unavailable"
      )
      pathRow(
        title: "Auth Token",
        value: store.daemonStatus?.diagnostics.authTokenPath ?? "Unavailable"
      )
      pathRow(
        title: "Events Log",
        value: store.daemonStatus?.diagnostics.eventsPath ?? "Unavailable"
      )
      pathRow(
        title: "Cache Root",
        value: store.daemonStatus?.diagnostics.cacheRoot ?? "Unavailable"
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
          value: store.daemonStatus?.diagnostics.authTokenPresent == true ? "Present" : "Missing",
          tint: store.daemonStatus?.diagnostics.authTokenPresent == true
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

      if let lastEvent = store.daemonStatus?.diagnostics.lastEvent {
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

  private var footer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let startedAt = store.health?.startedAt ?? store.daemonStatus?.manifest?.startedAt {
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
