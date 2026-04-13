import HarnessMonitorKit
import SwiftUI

struct PreferencesDiagnosticsSnapshot {
  let launchAgent: LaunchAgentStatus?
  let tokenPresent: Bool
  let projectCount: Int
  let worktreeCount: Int
  let sessionCount: Int
  let lastEvent: DaemonAuditEvent?
  let paths: PreferencesDiagnosticsPaths
  let recentEvents: [DaemonAuditEvent]

  @MainActor
  init(store: HarnessMonitorStore) {
    let workspaceDiagnostics = store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
    let launchAgent = store.daemonStatus?.launchAgent

    self.launchAgent = launchAgent
    tokenPresent = workspaceDiagnostics?.authTokenPresent ?? false
    projectCount = store.daemonStatus?.projectCount ?? store.projects.count
    worktreeCount = store.daemonStatus?.worktreeCount
      ?? store.projects.reduce(0) { $0 + $1.worktrees.count }
    sessionCount = store.daemonStatus?.sessionCount ?? store.sessions.count
    lastEvent = workspaceDiagnostics?.lastEvent
    paths = PreferencesDiagnosticsPaths(
      launchAgentPath: launchAgent?.path ?? "Unavailable",
      launchAgentDomain: launchAgent?.domainTarget,
      launchAgentService: launchAgent?.serviceTarget,
      manifestPath: workspaceDiagnostics?.manifestPath ?? "Unavailable",
      authTokenPath: workspaceDiagnostics?.authTokenPath ?? "Unavailable",
      eventsPath: workspaceDiagnostics?.eventsPath ?? "Unavailable",
      databasePath: workspaceDiagnostics?.databasePath ?? "Unavailable"
    )
    recentEvents = Array((store.diagnostics?.recentEvents ?? []).prefix(10))
  }
}

struct PreferencesDiagnosticsSection: View {
  let snapshot: PreferencesDiagnosticsSnapshot

  var body: some View {
    Form {
      PreferencesDiagnosticsOverview(
        launchAgent: snapshot.launchAgent,
        tokenPresent: snapshot.tokenPresent,
        projectCount: snapshot.projectCount,
        worktreeCount: snapshot.worktreeCount,
        sessionCount: snapshot.sessionCount,
        lastEvent: snapshot.lastEvent
      )
      PreferencesPathsSection(paths: snapshot.paths)
      PreferencesRecentEventsSection(events: snapshot.recentEvents)
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences Diagnostics Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesDiagnosticsSection(
    snapshot: PreferencesDiagnosticsSnapshot(store: store)
  )
  .frame(width: 720)
}
