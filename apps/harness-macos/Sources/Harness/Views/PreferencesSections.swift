import HarnessKit
import SwiftUI

struct PreferencesActionGrid: View {
  let isLoading: Bool
  let reconnect: @Sendable () async -> Void
  let refreshDiagnostics: @Sendable () async -> Void
  let startDaemon: @Sendable () async -> Void
  let installLaunchAgent: @Sendable () async -> Void
  let requestRemoveLaunchAgentConfirmation: @Sendable @MainActor () -> Void

  var body: some View {
    HarnessGlassContainer(spacing: 10) {
      HarnessWrapLayout(spacing: 10, lineSpacing: 10) {
        preferenceReconnectButton
        preferenceRefreshDiagnosticsButton
        preferenceStartDaemonButton
        preferenceInstallLaunchAgentButton
        preferenceRemoveLaunchAgentButton
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var preferenceReconnectButton: some View {
    HarnessAsyncActionButton(
      title: "Reconnect",
      tint: HarnessTheme.accent,
      variant: .bordered,
      isLoading: isLoading,
      accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect"),
      fillsWidth: false,
      action: reconnect
    )
  }

  private var preferenceRefreshDiagnosticsButton: some View {
    HarnessAsyncActionButton(
      title: "Refresh Diagnostics",
      tint: HarnessTheme.ink,
      variant: .bordered,
      isLoading: isLoading,
      accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Refresh Diagnostics"),
      fillsWidth: false,
      action: refreshDiagnostics
    )
  }

  private var preferenceStartDaemonButton: some View {
    HarnessAsyncActionButton(
      title: "Start Daemon",
      tint: HarnessTheme.success,
      variant: .prominent,
      isLoading: isLoading,
      accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon"),
      fillsWidth: false,
      action: startDaemon
    )
  }

  private var preferenceInstallLaunchAgentButton: some View {
    HarnessAsyncActionButton(
      title: "Install Launch Agent",
      tint: HarnessTheme.warmAccent,
      variant: .bordered,
      isLoading: isLoading,
      accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Install Launch Agent"),
      fillsWidth: false,
      action: installLaunchAgent
    )
  }

  private var preferenceRemoveLaunchAgentButton: some View {
    HarnessAsyncActionButton(
      title: "Remove Launch Agent",
      tint: HarnessTheme.danger,
      variant: .bordered,
      isLoading: isLoading,
      accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Remove Launch Agent"),
      fillsWidth: false,
      action: {
        await requestRemoveLaunchAgentConfirmation()
      }
    )
  }
}

struct PreferencesOverviewGrid: View {
  let endpoint: String
  let version: String
  let launchAgentState: String
  let launchAgentCaption: String
  let cacheEntryCount: Int
  let sessionCount: Int

  var body: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 180,
      maximumColumns: 4,
      spacing: 14
    ) {
      endpointMetric
      versionMetric
      launchdMetric
      cachedSessionsMetric
    }
  }

  private func overviewMetric(title: String, value: String, caption: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.headline, design: .rounded, weight: .semibold))
        .textSelection(.enabled)
        .contentTransition(.numericText())
      Text(caption)
        .font(.caption)
        .foregroundStyle(HarnessTheme.secondaryInk)
        .lineLimit(2, reservesSpace: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(minHeight: 88, contentPadding: 14)
    .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard(title))
  }

  private var endpointMetric: some View {
    overviewMetric(
      title: "Endpoint",
      value: endpoint,
      caption: "Local control plane"
    )
  }

  private var versionMetric: some View {
    overviewMetric(
      title: "Version",
      value: version,
      caption: "Daemon build"
    )
  }

  private var launchdMetric: some View {
    overviewMetric(
      title: "Launchd",
      value: launchAgentState,
      caption: launchAgentCaption
    )
  }

  private var cachedSessionsMetric: some View {
    overviewMetric(
      title: "Cached Sessions",
      value: "\(cacheEntryCount)",
      caption: "\(sessionCount) indexed live sessions"
    )
  }
}

struct PreferencesPathsCard: View {
  let launchAgentPath: String
  let launchAgentDomain: String?
  let launchAgentService: String?
  let manifestPath: String
  let authTokenPath: String
  let eventsPath: String
  let cacheRoot: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Paths")
        .font(.system(.title3, design: .serif, weight: .semibold))
      if let launchAgentDomain, !launchAgentDomain.isEmpty {
        pathRow(title: "Launchd Domain", value: launchAgentDomain)
      }
      if let launchAgentService, !launchAgentService.isEmpty {
        pathRow(title: "Service Target", value: launchAgentService)
      }
      pathRow(title: "Launch Agent", value: launchAgentPath)
      pathRow(title: "Manifest", value: manifestPath)
      pathRow(title: "Auth Token", value: authTokenPath)
      pathRow(title: "Events Log", value: eventsPath)
      pathRow(title: "Cache Root", value: cacheRoot)
    }
    .harnessCard()
  }

  private func pathRow(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
  }
}

struct PreferencesDiagnosticsCard: View {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Diagnostics")
        .font(.system(.title3, design: .serif, weight: .semibold))
      HarnessAdaptiveGridLayout(minimumColumnWidth: 120, maximumColumns: 3, spacing: 14) {
        diagnosticBadge(
          title: "Token",
          value: tokenPresent ? "Present" : "Missing",
          tint: tokenPresent ? HarnessTheme.success : HarnessTheme.danger
        )
        diagnosticBadge(
          title: "Projects",
          value: "\(projectCount)",
          tint: HarnessTheme.accent
        )
        diagnosticBadge(
          title: "Sessions",
          value: "\(sessionCount)",
          tint: HarnessTheme.warmAccent
        )
      }

      if let launchAgent {
        VStack(alignment: .leading, spacing: 8) {
          Text("Launch Agent")
            .font(.headline)
          Text(launchAgent.lifecycleTitle)
            .font(.system(.body, design: .rounded, weight: .bold))
            .foregroundStyle(launchAgent.pid == nil ? HarnessTheme.accent : HarnessTheme.success)
          Text(launchAgent.lifecycleCaption)
            .font(.caption)
            .foregroundStyle(HarnessTheme.secondaryInk)
            .lineLimit(2)
        }
        .padding(14)
        .background {
          HarnessInsetPanelBackground(
            cornerRadius: 18,
            fillOpacity: 0.05,
            strokeOpacity: 0.10
          )
        }
      }

      if let lastEvent {
        VStack(alignment: .leading, spacing: 8) {
          Text("Latest Event")
            .font(.headline)
          Text(lastEvent.message)
            .font(.system(.body, design: .rounded, weight: .semibold))
          Text("\(lastEvent.level.uppercased()) • \(formatTimestamp(lastEvent.recordedAt))")
            .font(.caption.monospaced())
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        .padding(14)
        .background {
          HarnessInsetPanelBackground(
            cornerRadius: 18,
            fillOpacity: 0.05,
            strokeOpacity: 0.10
          )
        }
      } else {
        Text("No daemon audit events have been recorded yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
    }
    .harnessCard()
  }

  private func diagnosticBadge(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.bold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.body, design: .rounded, weight: .bold))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(14)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 18,
        fillOpacity: 0.05,
        strokeOpacity: 0.10
      )
    }
  }
}

struct PreferencesRecentEventsCard: View {
  let events: [DaemonAuditEvent]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Recent Events")
        .font(.system(.title3, design: .serif, weight: .semibold))

      if events.isEmpty {
        Text("No daemon events available from the live diagnostics stream yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      } else {
        HarnessGlassContainer(spacing: 12) {
          ForEach(events) { event in
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text(event.level.uppercased())
                  .font(.caption.bold())
                  .foregroundStyle(
                    event.level == "warn" ? HarnessTheme.caution : HarnessTheme.accent
                  )
                Spacer()
                Text(formatTimestamp(event.recordedAt))
                  .font(.caption.monospaced())
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              Text(event.message)
                .font(.system(.body, design: .rounded, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background {
              HarnessInsetPanelBackground(
                cornerRadius: 18,
                fillOpacity: 0.05,
                strokeOpacity: 0.10
              )
            }
          }
        }
      }
    }
    .harnessCard()
  }
}
