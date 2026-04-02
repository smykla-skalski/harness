import HarnessKit
import SwiftUI

struct PreferencesDiagnosticsPaths {
  let launchAgentPath: String
  let launchAgentDomain: String?
  let launchAgentService: String?
  let manifestPath: String
  let authTokenPath: String
  let eventsPath: String
  let cacheRoot: String
}

struct PreferencesDiagnosticsSection: View {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?
  let paths: PreferencesDiagnosticsPaths
  let recentEvents: [DaemonAuditEvent]

  var body: some View {
    Form {
      PreferencesDiagnosticsOverview(
        launchAgent: launchAgent,
        tokenPresent: tokenPresent,
        projectCount: projectCount,
        sessionCount: sessionCount,
        lastEvent: lastEvent
      )
      PreferencesPathsSection(
        launchAgentPath: paths.launchAgentPath,
        launchAgentDomain: paths.launchAgentDomain,
        launchAgentService: paths.launchAgentService,
        manifestPath: paths.manifestPath,
        authTokenPath: paths.authTokenPath,
        eventsPath: paths.eventsPath,
        cacheRoot: paths.cacheRoot
      )
      PreferencesRecentEventsSection(events: recentEvents)
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences Diagnostics Section") {
  let store = PreferencesPreviewSupport.makeStore()
  let paths = PreferencesDiagnosticsPaths(
    launchAgentPath: store.daemonStatus?.launchAgent.path ?? "Unavailable",
    launchAgentDomain: store.daemonStatus?.launchAgent.domainTarget,
    launchAgentService: store.daemonStatus?.launchAgent.serviceTarget,
    manifestPath: store.diagnostics?.workspace.manifestPath ?? "Unavailable",
    authTokenPath: store.diagnostics?.workspace.authTokenPath ?? "Unavailable",
    eventsPath: store.diagnostics?.workspace.eventsPath ?? "Unavailable",
    cacheRoot: store.diagnostics?.workspace.cacheRoot ?? "Unavailable"
  )

  PreferencesDiagnosticsSection(
    launchAgent: store.daemonStatus?.launchAgent,
    tokenPresent: store.diagnostics?.workspace.authTokenPresent ?? false,
    projectCount: store.daemonStatus?.projectCount ?? 0,
    sessionCount: store.daemonStatus?.sessionCount ?? 0,
    lastEvent: store.diagnostics?.workspace.lastEvent,
    paths: paths,
    recentEvents: Array((store.diagnostics?.recentEvents ?? []).prefix(10))
  )
  .frame(width: 720)
}
