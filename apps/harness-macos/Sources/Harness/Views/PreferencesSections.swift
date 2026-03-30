import HarnessKit
import SwiftUI

struct PreferencesActionGrid: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
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
      tint: HarnessTheme.accent(for: themeStyle),
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

struct PreferencesConnectionActionsCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let isReconnectLoading: Bool
  let isRefreshLoading: Bool
  let reconnect: @Sendable () async -> Void
  let refreshDiagnostics: @Sendable () async -> Void
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Connection Actions")
        .font(.system(.title3, weight: .semibold))

      HarnessGlassContainer(spacing: 10) {
        HarnessWrapLayout(spacing: 10, lineSpacing: 10) {
          HarnessAsyncActionButton(
            title: "Reconnect",
            tint: HarnessTheme.accent(for: themeStyle),
            variant: .prominent,
            isLoading: isReconnectLoading,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Connection Reconnect"
            ),
            action: reconnect
          )

          HarnessAsyncActionButton(
            title: "Refresh Diagnostics",
            tint: HarnessTheme.ink,
            variant: .bordered,
            isLoading: isRefreshLoading,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Connection Refresh Diagnostics"
            ),
            action: refreshDiagnostics
          )
        }
      }
    }
    .harnessCard()
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
    HarnessGlassContainer(spacing: 14) {
      HarnessAdaptiveGridLayout(
        minimumColumnWidth: 180,
        maximumColumns: 4,
        spacing: 14
      ) {
        PreferencesOverviewMetric(title: "Endpoint", value: endpoint, caption: "Local control plane")
        PreferencesOverviewMetric(title: "Version", value: version, caption: "Daemon build")
        PreferencesOverviewMetric(
          title: "Launchd", value: launchAgentState, caption: launchAgentCaption
        )
        PreferencesOverviewMetric(
          title: "Cached Sessions",
          value: "\(cacheEntryCount)",
          caption: "\(sessionCount) indexed live sessions"
        )
      }
    }
  }
}

private struct PreferencesOverviewMetric: View {
  let title: String
  let value: String
  let caption: String

  var body: some View {
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
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier(HarnessAccessibility.preferencesMetricCard(title))
  }
}

struct PreferencesStatusCard: View {
  let startedAt: String?
  let lastError: String?
  let lastAction: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Status")
        .font(.system(.title3, weight: .semibold))

      if let startedAt {
        statusRow(title: "Started", value: formatTimestamp(startedAt))
      }

      if let lastError, !lastError.isEmpty {
        statusRow(title: "Latest Error", value: lastError, valueColor: HarnessTheme.danger)
      } else if !lastAction.isEmpty {
        statusRow(title: "Last Action", value: lastAction)
      } else {
        Text("No recent daemon actions yet.")
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
    }
    .harnessCard()
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
    .accessibilityElement(children: .combine)
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
        .font(.system(.title3, weight: .semibold))
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
    .accessibilityElement(children: .combine)
  }
}

struct PreferencesDiagnosticsCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Diagnostics")
        .font(.system(.title3, weight: .semibold))
      HarnessAdaptiveGridLayout(minimumColumnWidth: 120, maximumColumns: 3, spacing: 14) {
        diagnosticBadge(
          title: "Token",
          value: tokenPresent ? "Present" : "Missing",
          tint: tokenPresent ? HarnessTheme.success : HarnessTheme.danger
        )
        diagnosticBadge(
          title: "Projects",
          value: "\(projectCount)",
          tint: HarnessTheme.accent(for: themeStyle)
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
            .foregroundStyle(
              launchAgent.pid == nil
                ? HarnessTheme.accent(for: themeStyle)
                : HarnessTheme.success
            )
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
    .accessibilityElement(children: .combine)
  }
}
