import Foundation
import HarnessMonitorKit

enum DashboardAgentsPreviewFixtures {
  static let liveAgents = [
    agent(
      .init(
        projectID: "harness-project",
        projectName: "harness",
        checkoutID: "main",
        checkoutName: "main",
        runtime: .terminal,
        managedID: "terminal-01",
        name: "Release checks",
        lifecycle: .active,
        summary: "Running the focused Monitor tests before delivery"
      )
    ),
    agent(
      .init(
        projectID: "harness-project",
        projectName: "harness",
        checkoutID: "main",
        checkoutName: "main",
        runtime: .codex,
        managedID: "codex-01",
        name: "Dashboard agent browser",
        lifecycle: .waiting,
        summary: "Waiting for preview approval before creating the signed replay commit"
      )
    ),
    agent(
      .init(
        projectID: "mesh-project",
        projectName: "kong-mesh",
        checkoutID: "jwt-review",
        checkoutName: "jwt-review",
        runtime: .acp,
        managedID: "agent-01",
        name: "JWT review",
        lifecycle: .idle,
        summary: "Review complete; no unresolved findings remain"
      )
    ),
  ]

  static let liveState = DashboardAgentBrowserViewState(
    agents: liveAgents,
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_200)
  )
  static let firstRunState = DashboardAgentBrowserViewState()
  static let loadingState = DashboardAgentBrowserViewState(
    isLoading: true,
    hasAttemptedLoad: true
  )
  static let emptyState = DashboardAgentBrowserViewState(
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_200)
  )
  static let cachedState = DashboardAgentBrowserViewState(
    agents: liveAgents.map(\.cachedCopy),
    hasAttemptedLoad: true,
    source: .cache,
    cachedAt: Date(timeIntervalSince1970: 1_785_663_600)
  )
  static let offlineState = DashboardAgentBrowserViewState(
    agents: liveAgents.map(\.cachedCopy),
    hasAttemptedLoad: true,
    source: .cache,
    issue: .offline("Daemon is offline"),
    cachedAt: Date(timeIntervalSince1970: 1_785_663_600)
  )
  @MainActor static var offlineBackgroundRefreshState: DashboardAgentBrowserViewState {
    let routeState = DashboardAgentsRouteState(viewState: offlineState)
    _ = routeState.beginLoad(force: false, presentation: .background)
    return routeState.viewState
  }
  static let failureState = DashboardAgentBrowserViewState(
    hasAttemptedLoad: true,
    source: .live,
    issue: .requestFailure("The daemon returned an unexpected response")
  )

  static let acpAgent = liveAgents[2]
  static let stoppedAcpAgent = DashboardAgentSummary(
    identity: acpAgent.identity,
    workspace: acpAgent.workspace,
    sessionID: acpAgent.sessionID,
    sessionAgentID: acpAgent.sessionAgentID,
    displayName: acpAgent.displayName,
    lifecycle: .stopped,
    summary: "Stopped after the provider completed its review",
    projectDirectory: acpAgent.projectDirectory,
    createdAt: acpAgent.createdAt,
    updatedAt: "2026-08-02T11:45:00Z",
    source: .live
  )
  static let stoppedAcpState = DashboardAgentBrowserViewState(
    agents: [stoppedAcpAgent],
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_500)
  )

  static let managedAcpDetail = DashboardAcpAgentDetail(
    agent: acpSnapshot(status: .active, pendingBatches: [permissionBatch]),
    inspect: acpInspect,
    transcript: [
      TimelineEntry(
        entryId: "preview-transcript-1",
        recordedAt: "2026-08-02T11:28:00Z",
        kind: "agent_message",
        sessionId: acpAgent.sessionID,
        agentId: acpAgent.sessionAgentID,
        taskId: nil,
        summary: "I reviewed the JWT validation path and found one permission-gated edit",
        payload: .null
      )
    ],
    providerSessions: [
      AcpProviderSession(
        sessionID: "provider-session-42",
        cwd: acpAgent.projectDirectory,
        title: "JWT validation review",
        updatedAt: "2026-08-02T11:29:00Z"
      )
    ],
    issues: []
  )

  static let unavailableAcpDetail = DashboardAcpAgentDetail(
    agent: nil,
    inspect: nil,
    transcript: [],
    providerSessions: [],
    issues: [
      "Managed agent unavailable: transport connection was lost",
      "Transcript unavailable: cached identity has no live runtime evidence",
    ]
  )

  static let stoppedAcpDetail = DashboardAcpAgentDetail(
    agent: acpSnapshot(status: .removed, pendingBatches: []),
    inspect: nil,
    transcript: [],
    providerSessions: [],
    issues: []
  )

  static let acpDescriptor = AcpAgentDescriptor(
    id: "copilot",
    displayName: "GitHub Copilot",
    capabilities: ["streaming", "permissions", "session-resume"],
    launchCommand: "copilot",
    launchArgs: ["--acp"],
    envPassthrough: ["PATH"],
    doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
  )
  static let acpProbe = AcpRuntimeProbe(
    agentId: "copilot",
    displayName: "GitHub Copilot",
    binaryPresent: true,
    authState: .ready,
    version: "1.2.3"
  )

  private static let permissionBatch = AcpPermissionBatch(
    batchId: "preview-permission-batch",
    acpId: acpAgent.managedAgentID,
    sessionId: acpAgent.sessionID,
    requests: [
      AcpPermissionItem(
        requestId: "preview-permission-request",
        sessionId: acpAgent.sessionID,
        toolCall: .object([
          "kind": .string("write"),
          "path": .string("pkg/xds/auth/jwt.go"),
        ]),
        options: [.string("allow"), .string("deny")]
      )
    ],
    createdAt: "2026-08-02T11:29:30Z",
    expiresAt: "2026-08-02T11:34:30Z"
  )

  private static let acpInspect = AcpAgentInspectSnapshot(
    acpId: acpAgent.managedAgentID,
    sessionId: acpAgent.sessionID,
    agentId: acpAgent.sessionAgentID ?? "preview-acp-worker",
    displayName: acpAgent.displayName,
    pid: 42_101,
    pgid: 42_101,
    uptimeMs: 180_000,
    lastUpdateAt: acpAgent.updatedAt,
    lastClientCallAt: acpAgent.updatedAt,
    watchdogState: "ready",
    permissionMode: "ask",
    pendingPermissions: 1,
    permissionQueueDepth: 1,
    terminalCount: 0,
    promptDeadlineRemainingMs: 45_000,
    handshake: AcpAgentHandshake(
      protocolVersion: 1,
      agentName: "copilot",
      agentVersion: "1.2.3",
      authMethodIds: ["oauth"],
      supportsLoadSession: true,
      supportsSessionList: true,
      supportsSessionResume: true,
      supportsSessionClose: true,
      supportsSessionDelete: true,
      supportsLogout: true
    ),
    sessionState: AcpAgentSessionState(
      currentModeId: "agent",
      availableCommands: ["review", "explain"],
      title: "JWT validation review",
      updatedAt: "2026-08-02T11:29:00Z"
    )
  )

  private static func acpSnapshot(
    status: AgentStatus,
    pendingBatches: [AcpPermissionBatch]
  ) -> AcpAgentSnapshot {
    AcpAgentSnapshot(
      acpId: acpAgent.managedAgentID,
      sessionId: acpAgent.sessionID,
      agentId: acpAgent.sessionAgentID ?? "preview-acp-worker",
      displayName: acpAgent.displayName,
      status: status,
      pid: 42_101,
      pgid: 42_101,
      projectDir: acpAgent.projectDirectory,
      pendingPermissions: pendingBatches.flatMap(\.requests).count,
      permissionQueueDepth: pendingBatches.count,
      pendingPermissionBatches: pendingBatches,
      terminalCount: 0,
      createdAt: acpAgent.createdAt,
      updatedAt: acpAgent.updatedAt
    )
  }

  private static func agent(_ spec: DashboardAgentPreviewSpec) -> DashboardAgentSummary {
    let workspaceIdentity = DashboardAgentWorkspaceIdentity(
      projectID: spec.projectID,
      checkoutID: spec.checkoutID
    )
    let path = "/Users/example/Projects/\(spec.projectName)/\(spec.checkoutName)"
    let sessionAgentID: String? =
      switch spec.runtime {
      case .acp: "preview-acp-worker"
      case .codex: "preview-codex-worker"
      case .terminal: "preview-terminal-worker"
      }
    return DashboardAgentSummary(
      identity: DashboardAgentIdentity(
        workspace: workspaceIdentity,
        runtimeKind: spec.runtime,
        managedAgentID: spec.managedID
      ),
      workspace: DashboardAgentWorkspace(
        identity: workspaceIdentity,
        projectName: spec.projectName,
        checkoutName: spec.checkoutName,
        checkoutRoot: path
      ),
      sessionID: "opaque-preview-correlation",
      sessionAgentID: sessionAgentID,
      displayName: spec.name,
      lifecycle: spec.lifecycle,
      summary: spec.summary,
      projectDirectory: path,
      createdAt: "2026-08-02T10:00:00Z",
      updatedAt: "2026-08-02T11:30:00Z",
      source: .live
    )
  }
}
