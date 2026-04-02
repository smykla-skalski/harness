import HarnessKit
import SwiftUI

struct PreferencesActionButtons: View {
  let isLoading: Bool
  let reconnect: HarnessAsyncActionButton.Action
  let refreshDiagnostics: HarnessAsyncActionButton.Action
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let removeLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
      HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
        HarnessAsyncActionButton(
          title: "Reconnect",
          tint: nil,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Reconnect"),
          action: reconnect
        )
        HarnessAsyncActionButton(
          title: "Refresh Diagnostics",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Refresh Diagnostics"
          ),
          action: refreshDiagnostics
        )
        HarnessAsyncActionButton(
          title: "Start Daemon",
          tint: nil,
          variant: .prominent,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton("Start Daemon"),
          action: startDaemon
        )
        HarnessAsyncActionButton(
          title: "Install Launch Agent",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Install Launch Agent"
          ),
          action: installLaunchAgent
        )
        HarnessAsyncActionButton(
          title: "Remove Launch Agent",
          tint: .red,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
            "Remove Launch Agent"
          ),
          action: removeLaunchAgent
        )
      }
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
        .scaledFont(.caption.monospaced())
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
        HarnessGlassControlGroup(spacing: HarnessTheme.itemSpacing) {
          HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
            HarnessAsyncActionButton(
              title: "Reconnect",
              tint: nil,
              variant: .prominent,
              isLoading: store.connectionState == .connecting,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Reconnect"
              ),
              action: reconnect
            )
            HarnessAsyncActionButton(
              title: "Refresh Diagnostics",
              tint: .secondary,
              variant: .bordered,
              isLoading: store.isDiagnosticsRefreshInFlight,
              accessibilityIdentifier: HarnessAccessibility.preferencesActionButton(
                "Connection Refresh Diagnostics"
              ),
              action: refreshDiagnostics
            )
          }
        }
      }
      PreferencesConnectionMetrics(
        metrics: store.connectionMetrics,
        events: store.connectionEvents
      )
    }
    .preferencesDetailFormStyle()
  }

  private func reconnect() async {
    await store.reconnect()
  }

  private func refreshDiagnostics() async {
    await store.refreshDiagnostics()
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
            .scaledFont(.caption)
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
          .scaledFont(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
  }
}

#Preview("Preferences Actions") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    Section("Actions") {
      PreferencesActionButtons(
        isLoading: false,
        reconnect: { await store.reconnect() },
        refreshDiagnostics: { await store.refreshDiagnostics() },
        startDaemon: { await store.startDaemon() },
        installLaunchAgent: { await store.installLaunchAgent() },
        removeLaunchAgent: { store.requestRemoveLaunchAgentConfirmation() }
      )
    }
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}

#Preview("Preferences Status") {
  Form {
    PreferencesStatusSection(
      startedAt: "2026-03-31T11:42:00Z",
      lastError: nil,
      lastAction: "Reconnect completed successfully."
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}

#Preview("Preferences Status Error") {
  Form {
    PreferencesStatusSection(
      startedAt: "2026-03-31T11:42:00Z",
      lastError: "Launch agent removal requires a manual retry.",
      lastAction: ""
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 520)
}

#Preview("Preferences Paths") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesPathsSection(
      launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
      launchAgentDomain: store.daemonStatus?.launchAgent.domainTarget,
      launchAgentService: store.daemonStatus?.launchAgent.serviceTarget,
      manifestPath: store.diagnostics?.workspace.manifestPath ?? "Unavailable",
      authTokenPath: store.diagnostics?.workspace.authTokenPath ?? "Unavailable",
      eventsPath: store.diagnostics?.workspace.eventsPath ?? "Unavailable",
      cacheRoot: store.diagnostics?.workspace.cacheRoot ?? "Unavailable"
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 720)
}

#Preview("Preferences Connection Section") {
  PreferencesConnectionSection(store: PreferencesPreviewSupport.makeStore())
    .frame(width: 720)
}

#Preview("Preferences Diagnostics Overview") {
  let store = PreferencesPreviewSupport.makeStore()

  Form {
    PreferencesDiagnosticsOverview(
      launchAgent: store.daemonStatus?.launchAgent,
      tokenPresent: store.diagnostics?.workspace.authTokenPresent ?? false,
      projectCount: store.daemonStatus?.projectCount ?? 0,
      sessionCount: store.daemonStatus?.sessionCount ?? 0,
      lastEvent: store.diagnostics?.workspace.lastEvent
    )
  }
  .preferencesDetailFormStyle()
  .frame(width: 560)
}

#Preview("Preferences Diagnostics Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesDiagnosticsSection(
    store: store,
    effectiveTokenPresent: store.diagnostics?.workspace.authTokenPresent ?? false,
    effectiveLastEvent: store.diagnostics?.workspace.lastEvent
  )
  .frame(width: 720)
}
