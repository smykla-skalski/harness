import HarnessMonitorKit
import SwiftUI

struct PreferencesDiagnosticsSection: View {
  let store: HarnessMonitorStore

  private var workspaceDiagnostics: DaemonDiagnostics? {
    store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
  }

  private var paths: PreferencesDiagnosticsPaths {
    let agent = store.daemonStatus?.launchAgent
    return PreferencesDiagnosticsPaths(
      launchAgentPath: agent?.path ?? "Unavailable",
      launchAgentDomain: agent?.domainTarget,
      launchAgentService: agent?.serviceTarget,
      manifestPath: workspaceDiagnostics?.manifestPath ?? "Unavailable",
      authTokenPath: workspaceDiagnostics?.authTokenPath ?? "Unavailable",
      eventsPath: workspaceDiagnostics?.eventsPath ?? "Unavailable",
      databasePath: workspaceDiagnostics?.databasePath ?? "Unavailable"
    )
  }

  var body: some View {
    Form {
      PreferencesDiagnosticsOverview(
        launchAgent: store.daemonStatus?.launchAgent,
        tokenPresent: workspaceDiagnostics?.authTokenPresent ?? false,
        projectCount: store.daemonStatus?.projectCount ?? store.projects.count,
        worktreeCount: store.daemonStatus?.worktreeCount ?? store.projects.reduce(0) { $0 + $1.worktrees.count },
        sessionCount: store.daemonStatus?.sessionCount ?? store.sessions.count,
        lastEvent: workspaceDiagnostics?.lastEvent
      )
      PreferencesPathsSection(paths: paths)
      PreferencesRecentEventsSection(
        events: Array((store.diagnostics?.recentEvents ?? []).prefix(10))
      )
    }
    .preferencesDetailFormStyle()
  }
}

#Preview("Preferences Diagnostics Section") {
  PreferencesDiagnosticsSection(
    store: PreferencesPreviewSupport.makeStore()
  )
  .frame(width: 720)
}
