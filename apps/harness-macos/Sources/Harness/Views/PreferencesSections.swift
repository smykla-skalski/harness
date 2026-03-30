import HarnessKit
import SwiftUI

struct PreferencesActionButtons: View {
  let isLoading: Bool
  let reconnect: @Sendable () async -> Void
  let refreshDiagnostics: @Sendable () async -> Void
  let startDaemon: @Sendable () async -> Void
  let installLaunchAgent: @Sendable () async -> Void
  let requestRemoveLaunchAgentConfirmation:
    @Sendable @MainActor () -> Void

  var body: some View {
    Group {
      HStack(spacing: 8) {
        Button("Reconnect") {
          Task { await reconnect() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesActionButton(
            "Reconnect"
          )
        )
        Button("Refresh Diagnostics") {
          Task { await refreshDiagnostics() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesActionButton(
            "Refresh Diagnostics"
          )
        )
        Button("Start Daemon") {
          Task { await startDaemon() }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesActionButton(
            "Start Daemon"
          )
        )
      }
      HStack(spacing: 8) {
        Button("Install Launch Agent") {
          Task { await installLaunchAgent() }
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesActionButton(
            "Install Launch Agent"
          )
        )
        Button("Remove Launch Agent", role: .destructive) {
          requestRemoveLaunchAgentConfirmation()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(
          HarnessAccessibility.preferencesActionButton(
            "Remove Launch Agent"
          )
        )
      }
    }
    .disabled(isLoading)
  }
}

struct PreferencesStatusSection: View {
  let startedAt: String?
  let lastError: String?
  let lastAction: String

  var body: some View {
    Section("Status") {
      if let startedAt {
        LabeledContent(
          "Started", value: formatTimestamp(startedAt)
        )
      }
      if let lastError, !lastError.isEmpty {
        LabeledContent("Latest Error") {
          Text(lastError)
            .foregroundStyle(.red)
        }
      } else if !lastAction.isEmpty {
        LabeledContent("Last Action", value: lastAction)
      } else {
        Text("No recent daemon actions yet.")
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct PreferencesPathsSection: View {
  let launchAgentPath: String
  let launchAgentDomain: String?
  let launchAgentService: String?
  let manifestPath: String
  let authTokenPath: String
  let eventsPath: String
  let cacheRoot: String

  var body: some View {
    Section("Paths") {
      if let domain = launchAgentDomain, !domain.isEmpty {
        pathRow("Launchd Domain", value: domain)
      }
      if let service = launchAgentService, !service.isEmpty {
        pathRow("Service Target", value: service)
      }
      pathRow("Launch Agent", value: launchAgentPath)
      pathRow("Manifest", value: manifestPath)
      pathRow("Auth Token", value: authTokenPath)
      pathRow("Events Log", value: eventsPath)
      pathRow("Cache Root", value: cacheRoot)
    }
  }

  private func pathRow(
    _ title: String, value: String
  ) -> some View {
    LabeledContent(title) {
      Text(value)
        .font(.caption.monospaced())
        .textSelection(.enabled)
    }
  }
}

struct PreferencesConnectionSection: View {
  @Bindable var store: HarnessStore

  var body: some View {
    Form {
      Section("Actions") {
        HStack(spacing: 8) {
          Button("Reconnect") {
            Task { await store.reconnect() }
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.connectionState == .connecting)
          .accessibilityIdentifier(
            HarnessAccessibility.preferencesActionButton(
              "Connection Reconnect"
            )
          )
          Button("Refresh Diagnostics") {
            Task { await store.refreshDiagnostics() }
          }
          .buttonStyle(.bordered)
          .disabled(store.isDiagnosticsRefreshInFlight)
          .accessibilityIdentifier(
            HarnessAccessibility.preferencesActionButton(
              "Connection Refresh Diagnostics"
            )
          )
        }
      }
      PreferencesConnectionMetrics(
        metrics: store.connectionMetrics,
        events: store.connectionEvents
      )
    }
    .formStyle(.grouped)
  }
}

struct PreferencesDiagnosticsSection: View {
  @Bindable var store: HarnessStore
  let effectiveTokenPresent: Bool
  let effectiveLastEvent: DaemonAuditEvent?

  var body: some View {
    Form {
      PreferencesDiagnosticsOverview(
        launchAgent: store.daemonStatus?.launchAgent,
        tokenPresent: effectiveTokenPresent,
        projectCount: store.daemonStatus?.projectCount ?? 0,
        sessionCount: store.daemonStatus?.sessionCount ?? 0,
        lastEvent: effectiveLastEvent
      )
      PreferencesPathsSection(
        launchAgentPath:
          store.daemonStatus?.launchAgent.path
            ?? "Unavailable",
        launchAgentDomain:
          store.daemonStatus?.launchAgent.domainTarget,
        launchAgentService:
          store.daemonStatus?.launchAgent.serviceTarget,
        manifestPath:
          store.diagnostics?.workspace.manifestPath
            ?? store.daemonStatus?.diagnostics.manifestPath
            ?? "Unavailable",
        authTokenPath:
          store.diagnostics?.workspace.authTokenPath
            ?? store.daemonStatus?.diagnostics.authTokenPath
            ?? "Unavailable",
        eventsPath:
          store.diagnostics?.workspace.eventsPath
            ?? store.daemonStatus?.diagnostics.eventsPath
            ?? "Unavailable",
        cacheRoot:
          store.diagnostics?.workspace.cacheRoot
            ?? store.daemonStatus?.diagnostics.cacheRoot
            ?? "Unavailable"
      )
      PreferencesRecentEventsSection(
        events: Array(
          (store.diagnostics?.recentEvents ?? []).prefix(10)
        )
      )
    }
    .formStyle(.grouped)
  }
}

struct PreferencesDiagnosticsOverview: View {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?

  var body: some View {
    Section("Overview") {
      LabeledContent("Token") {
        Text(tokenPresent ? "Present" : "Missing")
          .foregroundStyle(
            tokenPresent ? Color.green : Color.red
          )
      }
      LabeledContent("Projects", value: "\(projectCount)")
      LabeledContent("Sessions", value: "\(sessionCount)")
    }

    if let launchAgent {
      Section("Launch Agent") {
        LabeledContent("Status") {
          Text(launchAgent.lifecycleTitle)
            .foregroundStyle(
              launchAgent.pid == nil
                ? Color.primary : Color.green
            )
        }
        if !launchAgent.lifecycleCaption.isEmpty {
          Text(launchAgent.lifecycleCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }

    if let lastEvent {
      Section("Latest Event") {
        LabeledContent("Level") {
          Text(lastEvent.level.uppercased())
        }
        Text(lastEvent.message)
        Text(formatTimestamp(lastEvent.recordedAt))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }
}
