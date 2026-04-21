import HarnessMonitorKit
import SwiftUI

public struct PreferencesDiagnosticsSnapshot {
  public let launchAgent: LaunchAgentStatus?
  public let tokenPresent: Bool
  public let projectCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int
  public let externalSessionCount: Int
  public let lastExternalSessionAttachOutcome: String?
  public let lastExternalSessionAttachSucceeded: Bool?
  public let lastEvent: DaemonAuditEvent?
  public let paths: PreferencesDiagnosticsPaths
  public let recentEvents: [DaemonAuditEvent]

  @MainActor
  public init(store: HarnessMonitorStore) {
    let workspaceDiagnostics = store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
    let launchAgent = store.daemonStatus?.launchAgent

    self.launchAgent = launchAgent
    tokenPresent = workspaceDiagnostics?.authTokenPresent ?? false
    projectCount = store.daemonStatus?.projectCount ?? store.projects.count
    worktreeCount =
      store.daemonStatus?.worktreeCount
      ?? store.projects.reduce(0) { $0 + $1.worktrees.count }
    sessionCount = store.daemonStatus?.sessionCount ?? store.sessions.count
    externalSessionCount = store.sessions.filter { $0.externalOrigin != nil }.count
    lastExternalSessionAttachOutcome = store.lastExternalSessionAttachOutcome?.message
    lastExternalSessionAttachSucceeded = store.lastExternalSessionAttachOutcome?.succeeded
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

public struct PreferencesDiagnosticsSection: View {
  public let snapshot: PreferencesDiagnosticsSnapshot

  public init(snapshot: PreferencesDiagnosticsSnapshot) {
    self.snapshot = snapshot
  }

  public var body: some View {
    Form {
      PreferencesDiagnosticsOverview(
        launchAgent: snapshot.launchAgent,
        tokenPresent: snapshot.tokenPresent,
        projectCount: snapshot.projectCount,
        worktreeCount: snapshot.worktreeCount,
        sessionCount: snapshot.sessionCount,
        externalSessionCount: snapshot.externalSessionCount,
        lastExternalSessionAttachOutcome: snapshot.lastExternalSessionAttachOutcome,
        lastExternalSessionAttachSucceeded: snapshot.lastExternalSessionAttachSucceeded,
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
