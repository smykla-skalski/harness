import HarnessMonitorKit
import SwiftUI

public struct PreferencesDiagnosticsSnapshot {
  public struct AcpPermissionLogRun: Equatable {
    public let runID: String
    public let displayName: String
    public let path: String?
  }

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
  public let acpPermissionLogRuns: [AcpPermissionLogRun]

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
    acpPermissionLogRuns = store.selectedAcpInspectAgents
      .map { snapshot in
        AcpPermissionLogRun(
          runID: snapshot.sessionId,
          displayName: snapshot.displayName,
          path: snapshot.permissionLogPath
        )
      }
      .sorted { left, right in
        if left.displayName != right.displayName {
          return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
        return left.runID < right.runID
      }
  }
}

public struct PreferencesDiagnosticsSection: View {
  public let snapshot: PreferencesDiagnosticsSnapshot
  public let revealPermissionLog: (String, String?) -> RevealAcpPermissionLogResult
  @State private var permissionLogErrorsByRunID: [String: String] = [:]
  @State private var permissionLogRevealStatusesByRunID: [String: String] = [:]

  public init(
    snapshot: PreferencesDiagnosticsSnapshot,
    revealPermissionLog: @escaping (String, String?) -> RevealAcpPermissionLogResult = { _, _ in
      .unavailable
    }
  ) {
    self.snapshot = snapshot
    self.revealPermissionLog = revealPermissionLog
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
      PreferencesAcpPermissionLogSection(
        runs: snapshot.acpPermissionLogRuns,
        errorsByRunID: permissionLogErrorsByRunID,
        revealStatusesByRunID: permissionLogRevealStatusesByRunID,
        reveal: revealPermissionLog,
        onRevealed: { runID, message in
          permissionLogRevealStatusesByRunID[runID] = message
        },
        onError: { runID, message in
          permissionLogRevealStatusesByRunID.removeValue(forKey: runID)
          permissionLogErrorsByRunID[runID] = message
        },
        clearError: { runID in
          permissionLogErrorsByRunID.removeValue(forKey: runID)
        }
      )
      PreferencesPathsSection(paths: snapshot.paths)
      PreferencesRecentEventsSection(events: snapshot.recentEvents)
    }
    .preferencesDetailFormStyle()
    .onChange(of: snapshot.acpPermissionLogRuns.map(\.runID)) { _, runIDs in
      let activeIDs = Set(runIDs)
      permissionLogErrorsByRunID = permissionLogErrorsByRunID.filter { entry in
        activeIDs.contains(entry.key)
      }
      permissionLogRevealStatusesByRunID = permissionLogRevealStatusesByRunID.filter { entry in
        activeIDs.contains(entry.key)
      }
    }
  }
}

private struct PreferencesAcpPermissionLogSection: View {
  let runs: [PreferencesDiagnosticsSnapshot.AcpPermissionLogRun]
  let errorsByRunID: [String: String]
  let revealStatusesByRunID: [String: String]
  let reveal: (String, String?) -> RevealAcpPermissionLogResult
  let onRevealed: (String, String) -> Void
  let onError: (String, String) -> Void
  let clearError: (String) -> Void

  @ViewBuilder var body: some View {
    if !runs.isEmpty {
      Section("ACP Permission Logs") {
        ForEach(runs, id: \.runID) { run in
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            HarnessMonitorActionButton(
              title: "Reveal permission-log.ndjson in Finder (\(run.displayName))",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier:
                "harness.preferences.diagnostics.acp-permission-log.reveal.\(run.runID)",
            ) {
              let result = reveal(run.runID, run.path)
              if result == .revealed {
                clearError(run.runID)
                onRevealed(
                  run.runID,
                  "Reveal requested in Finder."
                )
              } else {
                onError(
                  run.runID,
                  "ACP permission log for this run is unavailable."
                )
              }
            }
            if let status = revealStatusesByRunID[run.runID] {
              PreferencesAcpPermissionLogRevealStatusRow(
                runID: run.runID,
                message: status
              )
            }
            if let error = errorsByRunID[run.runID] {
              PreferencesAcpPermissionLogErrorRow(
                runID: run.runID,
                message: error
              )
            }
          }
        }
      }
    }
  }
}

private struct PreferencesAcpPermissionLogRevealStatusRow: View {
  let runID: String
  let message: String

  private var identifier: String {
    HarnessMonitorAccessibility.preferencesAcpPermissionLogRevealStatus(runID)
  }

  var body: some View {
    LabeledContent("Status") {
      Text(message)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.success)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status")
    .accessibilityValue(message)
    .accessibilityLiveRegion(.polite)
    .accessibilityIdentifier(identifier)
    .overlay {
      AccessibilityTextMarker(
        identifier: "\(identifier).probe",
        text: message
      )
    }
  }
}

private struct PreferencesAcpPermissionLogErrorRow: View {
  let runID: String
  let message: String

  private var identifier: String {
    "harness.preferences.diagnostics.acp-permission-log.error.\(runID)"
  }

  var body: some View {
    LabeledContent("Error") {
      Text(message)
        .scaledFont(.caption)
        .foregroundStyle(HarnessMonitorTheme.danger)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Error")
    .accessibilityValue(message)
    .accessibilityLiveRegion(.polite)
    .accessibilityIdentifier(identifier)
    .overlay {
      AccessibilityTextMarker(
        identifier: "\(identifier).probe",
        text: message
      )
    }
  }
}

#Preview("Preferences Diagnostics Section") {
  let store = PreferencesPreviewSupport.makeStore()

  PreferencesDiagnosticsSection(
    snapshot: PreferencesDiagnosticsSnapshot(store: store)
  )
  .frame(width: 720)
}
