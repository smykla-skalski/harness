import Foundation
import SwiftData

public enum PreviewHostBridgeReconfigureBehavior: String, Sendable {
  case unsupported
  case apply
  case bridgeStopped = "bridge-stopped"
  case missingRoute = "missing-route"
}

public struct PreviewHostBridgeOverride: Sendable {
  public let bridgeStatus: BridgeStatusReport
  public let reconfigureBehavior: PreviewHostBridgeReconfigureBehavior

  public init(
    bridgeStatus: BridgeStatusReport,
    reconfigureBehavior: PreviewHostBridgeReconfigureBehavior
  ) {
    self.bridgeStatus = bridgeStatus
    self.reconfigureBehavior = reconfigureBehavior
  }

  public var hostBridgeManifest: HostBridgeManifest {
    bridgeStatus.hostBridgeManifest
  }
}

public enum PreviewCodexStartBehavior: String, Sendable {
  case unsupported
  case success
  case unavailableRunningBridge = "unavailable-running-bridge"
}

@MainActor
public enum HarnessMonitorPreviewStoreFactory {
  public static let previewContainer: ModelContainer = {
    do {
      return try HarnessMonitorModelContainer.preview()
    } catch {
      fatalError("Preview ModelContainer failed: \(error)")
    }
  }()

  public enum Scenario: Sendable {
    case dashboardLanding
    case dashboardLoaded
    case cockpitLoaded
    case emptyCockpit
    case toolbarCountRegression
    case codexApprovalUnification
    case agentTuiOverflow
    case taskDropCockpit
    case offlineCached
    case sidebarOverflow
    case empty
  }

  public static func makeStore(
    for scenario: Scenario,
    hostBridgeOverride: PreviewHostBridgeOverride? = nil,
    codexStartBehavior: PreviewCodexStartBehavior = .unsupported,
    actionDelay: Duration? = nil,
    modelContainer: ModelContainer? = nil,
    persistenceError: String? = nil,
    voiceCapture: any VoiceCaptureProviding = PreviewVoiceCaptureService()
  ) -> HarnessMonitorStore {
    let configuration = configuration(for: scenario)
    let isDaemonRunning =
      switch configuration.connectionState {
      case .online:
        true
      case .idle, .connecting, .offline:
        false
      }
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(
        fixtures: configuration.fixtures,
        isDaemonRunning: isDaemonRunning,
        isLaunchAgentInstalled: !configuration.fixtures.sessions.isEmpty,
        hostBridgeOverride: hostBridgeOverride,
        actionDelay: actionDelay,
        codexStartBehavior: codexStartBehavior
      ),
      voiceCapture: voiceCapture,
      modelContainer: modelContainer,
      persistenceError: persistenceError
    )
    store.connectionState = configuration.connectionState
    store.health = configuration.fixtures.health
    store.daemonStatus = configuration.statusReport
    store.connectionMetrics = configuration.connectionMetrics
    store.connectionEvents = configuration.connectionEvents
    store.sessionIndex.replaceSnapshot(
      projects: configuration.fixtures.projects,
      sessions: configuration.fixtures.sessions
    )
    store.client = PreviewHarnessClient(
      fixtures: configuration.fixtures,
      isLaunchAgentInstalled: !configuration.fixtures.sessions.isEmpty,
      hostBridgeState: PreviewHostBridgeState(override: hostBridgeOverride),
      actionDelay: actionDelay,
      codexStartBehavior: codexStartBehavior
    )
    store.bookmarkedSessionIds = configuration.bookmarkedSessionIDs
    store.sessionFilter = configuration.sessionFilter
    store.selectedSessionID = configuration.selectedSessionID
    store.selectedSession = configuration.selectedDetail
    store.timeline = configuration.timeline
    if let selectedSessionID = configuration.selectedSessionID {
      let initialAgentTuis = configuration.fixtures.agentTuisBySessionID[selectedSessionID] ?? []
      let roleByAgent = Dictionary(
        uniqueKeysWithValues: (configuration.selectedDetail?.agents ?? []).map {
          ($0.agentId, $0.role)
        }
      )
      let sortedAgentTuis = AgentTuiListResponse(tuis: initialAgentTuis)
        .canonicallySorted(roleByAgent: roleByAgent)
        .tuis
      store.selectedAgentTuis = sortedAgentTuis
      store.selectAgentTui(tuiID: sortedAgentTuis.first?.tuiId)
      let seedsPendingAcp =
        ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PENDING"] == "1"
        || ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"]
          == "1"
      if seedsPendingAcp {
        let pendingBatch = previewAcpPermissionBatch(sessionID: selectedSessionID)
        let previewAcpAgent = previewAcpAgentSnapshot(
          sessionID: selectedSessionID,
          pendingBatch: pendingBatch
        )
        store.selectedAcpAgents = [previewAcpAgent]
        store.selectedAcpInspectAgents = [
          PreviewHarnessClientState.inspectSnapshot(from: previewAcpAgent)
        ]
        store.selectedAcpInspectObservedAt = Date()
        if ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"]
          == "1"
        {
          store.presentingAcpPermissionBatch = pendingBatch
        }
        store.reconcileAcpPermissionDecisions()
      }
    }
    store.isSelectionLoading = false
    store.isShowingCachedData = configuration.isShowingCachedData
    store.persistedSessionCount = configuration.persistedSessionCount
    store.lastPersistedSnapshotAt = configuration.lastPersistedSnapshotAt
    store.synchronizeActionActor()
    return store
  }

  private static func previewAcpAgentSnapshot(
    sessionID: String,
    pendingBatch: AcpPermissionBatch
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: pendingBatch.acpId,
      sessionId: sessionID,
      agentId: "worker-codex",
      displayName: "worker-codex",
      status: .active,
      pid: 41_001,
      pgid: 41_001,
      projectDir: "/Users/example/Projects/harness",
      pendingPermissions: pendingBatch.requests.count,
      permissionQueueDepth: 0,
      pendingPermissionBatches: [pendingBatch],
      terminalCount: 0,
      createdAt: PreviewHarnessClientState.mutationTimestamp,
      updatedAt: PreviewHarnessClientState.mutationTimestamp
    )
  }

  private static func previewAcpPermissionBatch(sessionID: String) -> AcpPermissionBatch {
    AcpPermissionBatch(
      batchId: "preview-acp-permission-1",
      acpId: "preview-managed-agent-1",
      sessionId: sessionID,
      requests: [
        AcpPermissionItem(
          requestId: "preview-request-write",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("fs.write_text_file"),
            "path": .string("Sources/App.swift"),
          ]),
          options: []
        ),
        AcpPermissionItem(
          requestId: "preview-request-terminal",
          sessionId: sessionID,
          toolCall: .object([
            "kind": .string("terminal.create"),
            "command": .string("swift test"),
          ]),
          options: []
        ),
      ],
      createdAt: PreviewHarnessClientState.mutationTimestamp
    )
  }
}

struct PreviewStoreConfiguration {
  let mode: PreviewDaemonController.Mode
  let fixtures: PreviewHarnessClient.Fixtures
  let connectionState: HarnessMonitorStore.ConnectionState
  let statusReport: DaemonStatusReport
  let connectionMetrics: ConnectionMetrics
  let connectionEvents: [ConnectionEvent]
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessMonitorStore.SessionFilter
  let selectedSessionID: String?
  let selectedDetail: SessionDetail?
  let timeline: [TimelineEntry]
  let isShowingCachedData: Bool
  let persistedSessionCount: Int
  let lastPersistedSnapshotAt: Date?
}

struct PreviewSelectionState {
  let bookmarkedSessionIDs: Set<String>
  let sessionFilter: HarnessMonitorStore.SessionFilter
  let selectedSessionID: String?
  let selectedDetail: SessionDetail?
  let timeline: [TimelineEntry]
}

struct PreviewPersistenceState {
  let isShowingCachedData: Bool
  let persistedSessionCount: Int
  let lastPersistedSnapshotAt: Date?

  static let unavailable = Self(
    isShowingCachedData: false,
    persistedSessionCount: 0,
    lastPersistedSnapshotAt: nil
  )
}
