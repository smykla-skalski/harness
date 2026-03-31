import HarnessKit
import SwiftUI

struct PreferencesActionButtons: View {
  let store: HarnessStore
  let isLoading: Bool

  var body: some View {
    HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
      HarnessAsyncActionButton(
        title: "Reconnect",
        tint: nil,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect"),
        store: store,
        storeAction: .reconnect
      )
      HarnessAsyncActionButton(
        title: "Refresh Diagnostics",
        tint: .secondary,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
          "Refresh Diagnostics"
        ),
        store: store,
        storeAction: .refreshDiagnostics
      )
      HarnessAsyncActionButton(
        title: "Start Daemon",
        tint: nil,
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon"),
        store: store,
        storeAction: .startDaemon
      )
      HarnessAsyncActionButton(
        title: "Install Launch Agent",
        tint: .secondary,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
          "Install Launch Agent"
        ),
        store: store,
        storeAction: .installLaunchAgent
      )
      HarnessAsyncActionButton(
        title: "Remove Launch Agent",
        tint: .red,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
          "Remove Launch Agent"
        ),
        store: store,
        storeAction: .removeLaunchAgent
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
            .foregroundStyle(HarnessTheme.danger)
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
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
  }
}

struct PreferencesConnectionSection: View {
  let store: HarnessStore

  var body: some View {
    Form {
      Section("Actions") {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          HarnessAsyncActionButton(
            title: "Reconnect",
            tint: nil,
            variant: .prominent,
            isLoading: store.connectionState == .connecting,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Connection Reconnect"
            ),
            store: store,
            storeAction: .reconnect
          )
          HarnessAsyncActionButton(
            title: "Refresh Diagnostics",
            tint: .secondary,
            variant: .bordered,
            isLoading: store.isDiagnosticsRefreshInFlight,
            accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
              "Connection Refresh Diagnostics"
            ),
            store: store,
            storeAction: .refreshDiagnostics
          )
        }
      }
      PreferencesConnectionMetrics(
        metrics: store.connectionMetrics,
        events: store.connectionEvents
      )
    }
    .preferencesDetailFormStyle()
  }
}

struct PreferencesDiagnosticsSection: View {
  let store: HarnessStore
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
    .preferencesDetailFormStyle()
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
        Label(
          tokenPresent ? "Present" : "Missing",
          systemImage: tokenPresent ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(
          tokenPresent ? HarnessTheme.success : HarnessTheme.danger
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
                ? HarnessTheme.ink : HarnessTheme.success
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
            .tracking(HarnessTheme.uppercaseTracking)
        }
        Text(lastEvent.message)
        Text(formatTimestamp(lastEvent.recordedAt))
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }
}
