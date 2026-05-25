import HarnessMonitorKit
import SwiftUI

public struct SettingsDiagnosticsSnapshot: Sendable {
  public struct AcpPermissionLogRun: Equatable, Identifiable, Sendable {
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
  public let githubApi: GitHubApiDiagnostics?
  public let paths: SettingsDiagnosticsPaths
  public let recentEvents: [DaemonAuditEvent]
  public let acpPermissionLogRuns: [AcpPermissionLogRun]

  public init(input: SettingsDiagnosticsSnapshotInput) {
    launchAgent = input.launchAgent
    mcpStatus = input.mcpStatus
    tokenPresent = input.workspaceDiagnostics?.authTokenPresent ?? false
    projectCount = input.daemonProjectCount ?? input.projects.count
    worktreeCount =
      input.daemonWorktreeCount
      ?? input.projects.reduce(0) { $0 + $1.worktrees.count }
    sessionCount = input.daemonSessionCount ?? input.sessions.count
    externalSessionCount = input.sessions.filter { $0.externalOrigin != nil }.count
    lastExternalSessionAttachOutcome = input.lastExternalSessionAttachOutcome
    lastExternalSessionAttachSucceeded = input.lastExternalSessionAttachSucceeded
    lastEvent = input.workspaceDiagnostics?.lastEvent
    githubApi = input.githubApi
    paths = SettingsDiagnosticsPaths(
      launchAgentPath: input.launchAgent?.path ?? "Unavailable",
      launchAgentDomain: input.launchAgent?.domainTarget,
      launchAgentService: input.launchAgent?.serviceTarget,
      manifestPath: input.workspaceDiagnostics?.manifestPath ?? "Unavailable",
      authTokenPath: input.workspaceDiagnostics?.authTokenPath ?? "Unavailable",
      eventsPath: input.workspaceDiagnostics?.eventsPath ?? "Unavailable",
      databasePath: input.workspaceDiagnostics?.databasePath ?? "Unavailable"
    )
    recentEvents = Array(input.recentEvents.prefix(10))
    acpPermissionLogRuns = input.selectedAcpInspectAgents
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

  @MainActor
  public init(store: HarnessMonitorStore) {
    let workspaceDiagnostics = store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics
    self.init(
      input: SettingsDiagnosticsSnapshotInput(
        workspaceDiagnostics: workspaceDiagnostics,
        launchAgent: store.daemonStatus?.launchAgent,
        mcpStatus: store.mcpStatus,
        daemonProjectCount: store.daemonStatus?.projectCount,
        daemonWorktreeCount: store.daemonStatus?.worktreeCount,
        daemonSessionCount: store.daemonStatus?.sessionCount,
        projects: store.projects,
        sessions: store.sessions,
        lastExternalSessionAttachOutcome: store.lastExternalSessionAttachOutcome?.message,
        lastExternalSessionAttachSucceeded: store.lastExternalSessionAttachOutcome?.succeeded,
        githubApi: store.diagnostics?.githubApi,
        recentEvents: store.diagnostics?.recentEvents ?? [],
        selectedAcpInspectAgents: store.selectedAcpInspectAgents
      )
    )
  }
}

public struct SettingsDiagnosticsSnapshotInput: Equatable, Sendable {
  public let workspaceDiagnostics: DaemonDiagnostics?
  public let launchAgent: LaunchAgentStatus?
  public let mcpStatus: HarnessMonitorMCPStatusSnapshot
  public let daemonProjectCount: Int?
  public let daemonWorktreeCount: Int?
  public let daemonSessionCount: Int?
  public let projects: [ProjectSummary]
  public let sessions: [SessionSummary]
  public let lastExternalSessionAttachOutcome: String?
  public let lastExternalSessionAttachSucceeded: Bool?
  public let githubApi: GitHubApiDiagnostics?
  public let recentEvents: [DaemonAuditEvent]
  public let selectedAcpInspectAgents: [AcpAgentInspectSnapshot]

  @MainActor
  public init(store: HarnessMonitorStore) {
    self.init(
      workspaceDiagnostics: store.diagnostics?.workspace ?? store.daemonStatus?.diagnostics,
      launchAgent: store.daemonStatus?.launchAgent,
      mcpStatus: store.mcpStatus,
      daemonProjectCount: store.daemonStatus?.projectCount,
      daemonWorktreeCount: store.daemonStatus?.worktreeCount,
      daemonSessionCount: store.daemonStatus?.sessionCount,
      projects: store.projects,
      sessions: store.sessions,
      lastExternalSessionAttachOutcome: store.lastExternalSessionAttachOutcome?.message,
      lastExternalSessionAttachSucceeded: store.lastExternalSessionAttachOutcome?.succeeded,
      githubApi: store.diagnostics?.githubApi,
      recentEvents: store.diagnostics?.recentEvents ?? [],
      selectedAcpInspectAgents: store.selectedAcpInspectAgents
    )
  }

  public init(
    workspaceDiagnostics: DaemonDiagnostics?,
    launchAgent: LaunchAgentStatus?,
    mcpStatus: HarnessMonitorMCPStatusSnapshot,
    daemonProjectCount: Int?,
    daemonWorktreeCount: Int?,
    daemonSessionCount: Int?,
    projects: [ProjectSummary],
    sessions: [SessionSummary],
    lastExternalSessionAttachOutcome: String?,
    lastExternalSessionAttachSucceeded: Bool?,
    githubApi: GitHubApiDiagnostics?,
    recentEvents: [DaemonAuditEvent],
    selectedAcpInspectAgents: [AcpAgentInspectSnapshot]
  ) {
    self.workspaceDiagnostics = workspaceDiagnostics
    self.launchAgent = launchAgent
    self.mcpStatus = mcpStatus
    self.daemonProjectCount = daemonProjectCount
    self.daemonWorktreeCount = daemonWorktreeCount
    self.daemonSessionCount = daemonSessionCount
    self.projects = projects
    self.sessions = sessions
    self.lastExternalSessionAttachOutcome = lastExternalSessionAttachOutcome
    self.lastExternalSessionAttachSucceeded = lastExternalSessionAttachSucceeded
    self.githubApi = githubApi
    self.recentEvents = recentEvents
    self.selectedAcpInspectAgents = selectedAcpInspectAgents
  }
}

actor SettingsDiagnosticsSnapshotWorker {
  func prepare(input: SettingsDiagnosticsSnapshotInput) -> SettingsDiagnosticsSnapshot {
    SettingsDiagnosticsSnapshot(input: input)
  }

  func waitForIdle() async {}
}

public struct SettingsDiagnosticsSection: View {
  public let snapshot: SettingsDiagnosticsSnapshot
  public let revealPermissionLog: (String, String?) -> RevealAcpPermissionLogResult
  public let repairLaunchAgent: (() async -> Void)?
  @State private var permissionLogErrorsByEntryID: [String: String] = [:]
  @State private var permissionLogRevealStatusesByEntryID: [String: String] = [:]
  @State private var isFullyExpanded = false

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
      if let githubApi = snapshot.githubApi {
        SettingsGitHubApiDiagnosticsSection(diagnostics: githubApi)
      }
      if isFullyExpanded {
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
    }
    .settingsDetailFormStyle()
    .task { await expandAfterFirstFrame() }
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

  private func expandAfterFirstFrame() async {
    guard !isFullyExpanded else { return }
    try? await Task.sleep(for: .milliseconds(40))
    isFullyExpanded = true
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
      Section {
        ForEach(runs) { run in
          VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
            HarnessMonitorActionButton(
              title: "Reveal permission-log.ndjson in Finder (\(run.displayName))",
              tint: .secondary,
              variant: .bordered,
              accessibilityIdentifier:
                HarnessMonitorAccessibility.settingsAcpPermissionLogRevealButton(
                  run.id
                ),
            ) {
              let result = reveal(run.sessionID, run.path)
              if result == .revealed {
                clearError(run.id)
                onRevealed(
                  run.id,
                  "Reveal requested in Finder"
                )
              } else {
                onError(
                  run.id,
                  "ACP permission log for this run is unavailable"
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
      } header: {
        Text("ACP Permission Logs")
          .harnessNativeFormSectionHeader()
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
