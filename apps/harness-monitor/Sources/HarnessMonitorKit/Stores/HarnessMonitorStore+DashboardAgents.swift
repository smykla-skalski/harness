import Foundation

extension HarnessMonitorStore {
  public func cachedDashboardAgents(
    sessions: [SessionSummary]
  ) async -> DashboardAgentCacheSnapshot {
    guard let cacheService else {
      return DashboardAgentCacheSnapshot(agents: [], cachedAt: nil)
    }
    let uniqueSessions = Self.uniqueDashboardAgentSessions(sessions)
    let details = await cacheService.loadSessionDetails(
      sessionIDs: uniqueSessions.map(\.sessionId)
    )
    let summariesByID = Dictionary(uniqueKeysWithValues: uniqueSessions.map { ($0.sessionId, $0) })
    let agents = details.values.flatMap { cached -> [DashboardAgentSummary] in
      let session = summariesByID[cached.detail.session.sessionId] ?? cached.detail.session
      return cached.detail.agents.compactMap { registration in
        Self.cachedDashboardAgent(registration: registration, session: session)
      }
    }
    return DashboardAgentCacheSnapshot(
      agents: DashboardAgentSummary.deduplicated(agents),
      cachedAt: lastPersistedSnapshotAt
    )
  }

  public func refreshDashboardAgents(
    sessions: [SessionSummary],
    cachedAgents: [DashboardAgentSummary]
  ) async -> DashboardAgentRefreshResult {
    guard case .online = connectionState else {
      let message: String
      if case .offline(let reason) = connectionState {
        message = reason
      } else {
        message = "Daemon is not connected"
      }
      return DashboardAgentRefreshResult(
        agents: cachedAgents,
        source: .cache,
        issue: .offline(message),
        refreshedAt: .now
      )
    }
    guard let client else {
      return DashboardAgentRefreshResult(
        agents: cachedAgents,
        source: .cache,
        issue: .requestFailure("Agent client is unavailable"),
        refreshedAt: .now
      )
    }

    let uniqueSessions = Self.uniqueDashboardAgentSessions(sessions)
    guard !uniqueSessions.isEmpty else {
      return DashboardAgentRefreshResult(
        agents: [],
        source: .live,
        issue: nil,
        refreshedAt: .now
      )
    }
    let cachedByIdentity = Dictionary(
      uniqueKeysWithValues: DashboardAgentSummary.deduplicated(cachedAgents).map {
        ($0.identity, $0)
      }
    )
    let loads = await Self.loadDashboardAgentSessions(
      uniqueSessions,
      using: client
    )
    var liveAgents: [DashboardAgentSummary] = []
    var successfulSessionIDs: Set<String> = []
    var failuresBySessionID: [String: String] = [:]
    for load in loads {
      switch load.result {
      case .success(let snapshots):
        successfulSessionIDs.insert(load.session.sessionId)
        liveAgents.append(
          contentsOf: snapshots.map { snapshot in
            let identity = Self.dashboardAgentIdentity(snapshot: snapshot, session: load.session)
            return Self.liveDashboardAgent(
              snapshot: snapshot,
              session: load.session,
              cached: cachedByIdentity[identity]
            )
          }
        )
      case .failure(let message):
        failuresBySessionID[load.session.sessionId] = message
      }
    }
    return DashboardAgentRefreshResult.merging(
      liveAgents: liveAgents,
      cachedAgents: cachedAgents,
      successfulSessionIDs: successfulSessionIDs,
      failuresBySessionID: failuresBySessionID
    )
  }
}

private struct DashboardAgentSessionLoad: Sendable {
  enum Result: Sendable {
    case success([ManagedAgentSnapshot])
    case failure(String)
  }

  let session: SessionSummary
  let result: Result
}

extension HarnessMonitorStore {
  nonisolated private static func loadDashboardAgentSessions(
    _ sessions: [SessionSummary],
    using client: any HarnessMonitorClientProtocol
  ) async -> [DashboardAgentSessionLoad] {
    await withTaskGroup(of: DashboardAgentSessionLoad.self) { group in
      for session in sessions {
        group.addTask {
          do {
            let response = try await client.managedAgents(sessionID: session.sessionId)
            return DashboardAgentSessionLoad(session: session, result: .success(response.agents))
          } catch {
            return DashboardAgentSessionLoad(
              session: session,
              result: .failure(error.localizedDescription)
            )
          }
        }
      }
      var results: [DashboardAgentSessionLoad] = []
      for await result in group {
        results.append(result)
      }
      return results
    }
  }

  nonisolated private static func uniqueDashboardAgentSessions(
    _ sessions: [SessionSummary]
  ) -> [SessionSummary] {
    var seen: Set<String> = []
    return sessions.filter { seen.insert($0.sessionId).inserted }
  }

  nonisolated private static func cachedDashboardAgent(
    registration: AgentRegistration,
    session: SessionSummary
  ) -> DashboardAgentSummary? {
    guard let managedAgent = registration.managedAgent else { return nil }
    let runtimeKind: DashboardAgentRuntimeKind
    switch managedAgent.kind {
    case .tui:
      runtimeKind = .terminal
    case .codex:
      runtimeKind = .codex
    case .acp:
      runtimeKind = .acp
    }
    let workspace = dashboardAgentWorkspace(session)
    return DashboardAgentSummary(
      identity: DashboardAgentIdentity(
        workspace: workspace.identity,
        runtimeKind: runtimeKind,
        managedAgentID: managedAgent.managedAgentID
      ),
      workspace: workspace,
      sessionID: session.sessionId,
      sessionAgentID: registration.sessionAgentID,
      displayName: registration.name,
      lifecycle: dashboardAgentLifecycle(registration.status),
      summary: registration.currentTaskId.map { "Working on \($0)" },
      projectDirectory: session.checkoutRoot,
      createdAt: registration.joinedAt,
      updatedAt: registration.updatedAt,
      source: .cache
    )
  }

  nonisolated private static func liveDashboardAgent(
    snapshot: ManagedAgentSnapshot,
    session: SessionSummary,
    cached: DashboardAgentSummary?
  ) -> DashboardAgentSummary {
    let workspace = dashboardAgentWorkspace(session)
    let presentation = dashboardAgentPresentation(snapshot, cached: cached)
    return DashboardAgentSummary(
      identity: dashboardAgentIdentity(snapshot: snapshot, session: session),
      workspace: workspace,
      sessionID: session.sessionId,
      sessionAgentID: snapshot.sessionAgentID,
      displayName: presentation.name,
      lifecycle: presentation.lifecycle,
      summary: presentation.summary,
      projectDirectory: presentation.projectDirectory,
      createdAt: presentation.createdAt,
      updatedAt: snapshot.updatedAt,
      source: .live
    )
  }

  nonisolated private static func dashboardAgentIdentity(
    snapshot: ManagedAgentSnapshot,
    session: SessionSummary
  ) -> DashboardAgentIdentity {
    let runtimeKind: DashboardAgentRuntimeKind
    switch snapshot.family {
    case .terminal:
      runtimeKind = .terminal
    case .codex:
      runtimeKind = .codex
    case .acp:
      runtimeKind = .acp
    }
    return DashboardAgentIdentity(
      workspace: dashboardAgentWorkspace(session).identity,
      runtimeKind: runtimeKind,
      managedAgentID: snapshot.managedAgentID
    )
  }

  nonisolated static func dashboardAgentWorkspace(
    _ session: SessionSummary
  ) -> DashboardAgentWorkspace {
    DashboardAgentWorkspace(
      identity: DashboardAgentWorkspaceIdentity(
        projectID: session.projectId,
        checkoutID: session.checkoutId
      ),
      projectName: session.projectName,
      checkoutName: session.checkoutDisplayName,
      checkoutRoot: session.checkoutRoot
    )
  }
}

private struct DashboardAgentPresentation {
  let name: String
  let lifecycle: DashboardAgentLifecycle
  let summary: String?
  let projectDirectory: String
  let createdAt: String
}

extension HarnessMonitorStore {
  nonisolated private static func dashboardAgentPresentation(
    _ snapshot: ManagedAgentSnapshot,
    cached: DashboardAgentSummary?
  ) -> DashboardAgentPresentation {
    switch snapshot {
    case .terminal(let terminal):
      return DashboardAgentPresentation(
        name: cached?.displayName ?? terminalRuntimeTitle(terminal.runtime),
        lifecycle: dashboardAgentLifecycle(terminal.status),
        summary: terminal.error?.nonempty ?? terminal.screen.text.lastNonemptyLine,
        projectDirectory: terminal.projectDir,
        createdAt: terminal.createdAt
      )
    case .codex(let codex):
      return DashboardAgentPresentation(
        name: codex.displayName?.nonempty ?? cached?.displayName ?? "Codex",
        lifecycle: dashboardAgentLifecycle(codex.status),
        summary: codex.error?.nonempty ?? codex.latestSummary?.nonempty
          ?? codex.finalMessage?.nonempty ?? codex.prompt.nonempty,
        projectDirectory: codex.projectDir,
        createdAt: codex.createdAt
      )
    case .acp(let acp):
      let permissionSummary =
        acp.pendingPermissions > 0
        ? "\(acp.pendingPermissions) permission requests waiting"
        : nil
      return DashboardAgentPresentation(
        name: acp.displayName.nonempty ?? cached?.displayName ?? "ACP agent",
        lifecycle: dashboardAgentLifecycle(acp.status),
        summary: permissionSummary ?? acp.stderrTail?.nonempty,
        projectDirectory: acp.projectDir,
        createdAt: acp.createdAt
      )
    }
  }

  nonisolated private static func terminalRuntimeTitle(_ runtime: String) -> String {
    AgentTuiRuntime(rawValue: runtime)?.title ?? runtime.nonempty ?? "Terminal agent"
  }

  nonisolated private static func dashboardAgentLifecycle(
    _ status: AgentTuiStatus
  ) -> DashboardAgentLifecycle {
    switch status {
    case .starting: .starting
    case .running: .active
    case .stopped, .exited: .stopped
    case .failed: .failed
    }
  }

  nonisolated private static func dashboardAgentLifecycle(
    _ status: CodexRunStatus
  ) -> DashboardAgentLifecycle {
    switch status {
    case .queued: .starting
    case .running: .active
    case .waitingApproval: .waiting
    case .completed: .completed
    case .failed: .failed
    case .cancelled: .stopped
    }
  }

  nonisolated private static func dashboardAgentLifecycle(
    _ status: AgentStatus
  ) -> DashboardAgentLifecycle {
    switch status {
    case .active: .active
    case .awaitingReview: .waiting
    case .idle: .idle
    case .disconnected: .disconnected
    case .removed: .stopped
    }
  }
}

extension String {
  fileprivate var nonempty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  fileprivate var lastNonemptyLine: String? {
    split(whereSeparator: \.isNewline)
      .reversed()
      .lazy
      .map(Self.init)
      .compactMap(\.nonempty)
      .first
  }
}
