import HarnessMonitorKit
import SwiftUI

public struct SettingsDiagnosticsSnapshot {
  public struct AcpPermissionLogRun: Equatable, Identifiable {
    public let id: String
    public let sessionID: String
    public let displayName: String
    public let path: String?
  }

  public let launchAgent: LaunchAgentStatus?
  public let mcpStatus: HarnessMonitorMCPStatusSnapshot
  public let tokenPresent: Bool
  public let projectCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int
  public let externalSessionCount: Int
  public let lastExternalSessionAttachOutcome: String?
  public let lastExternalSessionAttachSucceeded: Bool?
  public let lastEvent: DaemonAuditEvent?
  public let paths: SettingsDiagnosticsPaths
  public let recentEvents: [DaemonAuditEvent]
  public let acpPermissionLogRuns: [AcpPermissionLogRun]

  @MainActor
  public init(store: HarnessMonitorStore) {
    let workspaceDiagnostics = store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
    let launchAgent = store.daemonStatus?.launchAgent

    self.launchAgent = launchAgent
    mcpStatus = store.mcpStatus
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
    paths = SettingsDiagnosticsPaths(
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
          id: snapshot.acpId,
          sessionID: snapshot.sessionId,
          displayName: snapshot.displayName,
          path: snapshot.permissionLogPath
        )
      }
      .sorted { left, right in
        if left.displayName != right.displayName {
          return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
        }
        return left.id < right.id
      }
  }
}

public struct SettingsDiagnosticsSection: View {
  public let snapshot: SettingsDiagnosticsSnapshot
  public let revealPermissionLog: (String, String?) -> RevealAcpPermissionLogResult
  public let repairLaunchAgent: (() async -> Void)?
  @State private var permissionLogErrorsByEntryID: [String: String] = [:]
  @State private var permissionLogRevealStatusesByEntryID: [String: String] = [:]

  public init(
    snapshot: SettingsDiagnosticsSnapshot,
    revealPermissionLog: @escaping (String, String?) -> RevealAcpPermissionLogResult = { _, _ in
      .unavailable
    },
    repairLaunchAgent: (() async -> Void)? = nil
  ) {
    self.snapshot = snapshot
    self.revealPermissionLog = revealPermissionLog
    self.repairLaunchAgent = repairLaunchAgent
  }

  public var body: some View {
    Form {
      SettingsDiagnosticsOverview(
        launchAgent: snapshot.launchAgent,
        mcpStatus: snapshot.mcpStatus,
        tokenPresent: snapshot.tokenPresent,
        projectCount: snapshot.projectCount,
        worktreeCount: snapshot.worktreeCount,
        sessionCount: snapshot.sessionCount,
        externalSessionCount: snapshot.externalSessionCount,
        lastExternalSessionAttachOutcome: snapshot.lastExternalSessionAttachOutcome,
        lastExternalSessionAttachSucceeded: snapshot.lastExternalSessionAttachSucceeded,
        lastEvent: snapshot.lastEvent,
        repairLaunchAgent: repairLaunchAgent
      )
      SettingsAcpPermissionLogSection(
        runs: snapshot.acpPermissionLogRuns,
        errorsByEntryID: permissionLogErrorsByEntryID,
        revealStatusesByEntryID: permissionLogRevealStatusesByEntryID,
        reveal: revealPermissionLog,
        onRevealed: { entryID, message in
          permissionLogRevealStatusesByEntryID[entryID] = message
        },
        onError: { entryID, message in
          permissionLogRevealStatusesByEntryID.removeValue(forKey: entryID)
          permissionLogErrorsByEntryID[entryID] = message
        },
        clearError: { entryID in
          permissionLogErrorsByEntryID.removeValue(forKey: entryID)
        }
      )
      SettingsPathsSection(paths: snapshot.paths)
      SettingsRecentEventsSection(events: snapshot.recentEvents)
    }
    .settingsDetailFormStyle()
    .onChange(of: snapshot.acpPermissionLogRuns.map(\.id)) { _, entryIDs in
      let activeIDs = Set(entryIDs)
      permissionLogErrorsByEntryID = permissionLogErrorsByEntryID.filter { entry in
        activeIDs.contains(entry.key)
      }
      permissionLogRevealStatusesByEntryID = permissionLogRevealStatusesByEntryID.filter { entry in
        activeIDs.contains(entry.key)
      }
    }
  }
}

private struct SettingsAcpPermissionLogSection: View {
  let runs: [SettingsDiagnosticsSnapshot.AcpPermissionLogRun]
  let errorsByEntryID: [String: String]
  let revealStatusesByEntryID: [String: String]
  let reveal: (String, String?) -> RevealAcpPermissionLogResult
  let onRevealed: (String, String) -> Void
  let onError: (String, String) -> Void
  let clearError: (String) -> Void

  @ViewBuilder var body: some View {
    if !runs.isEmpty {
      Section("ACP Permission Logs") {
        ForEach(runs) { run in
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            HarnessMonitorActionButton(
              title: "Reveal permission-log.ndjson in Finder (\(run.displayName))",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier: HarnessMonitorAccessibility.settingsAcpPermissionLogRevealButton(
                run.id
              ),
            ) {
              let result = reveal(run.sessionID, run.path)
              if result == .revealed {
                clearError(run.id)
                onRevealed(
                  run.id,
                  "Reveal requested in Finder."
                )
              } else {
                onError(
                  run.id,
                  "ACP permission log for this run is unavailable."
                )
              }
            }
            if let status = revealStatusesByEntryID[run.id] {
              SettingsAcpPermissionLogRevealStatusRow(
                entryID: run.id,
                message: status
              )
            }
            if let error = errorsByEntryID[run.id] {
              SettingsAcpPermissionLogErrorRow(
                entryID: run.id,
                message: error
              )
            }
          }
        }
      }
    }
  }
}

private struct SettingsAcpPermissionLogRevealStatusRow: View {
  let entryID: String
  let message: String

  private var identifier: String {
    HarnessMonitorAccessibility.settingsAcpPermissionLogRevealStatus(entryID)
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

private struct SettingsAcpPermissionLogErrorRow: View {
  let entryID: String
  let message: String

  private var identifier: String {
    HarnessMonitorAccessibility.settingsAcpPermissionLogError(entryID)
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
