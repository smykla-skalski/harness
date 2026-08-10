extension HarnessMonitorStore {
  struct TaskBoardPushRefreshSelection: Equatable, Sendable {
    let items: Bool
    let orchestratorStatus: Bool
    let policyPipeline: Bool

    var hasWork: Bool { items || orchestratorStatus || policyPipeline }
  }

  func applyGlobalDataPushEventFromStream(_ event: DaemonPushEvent) async -> Bool {
    switch event.kind {
    case .auditEvent(let auditEvent):
      await applyApplicationAuditEventFromStream(auditEvent)
    case .githubDataChanged:
      applyGlobalPushEvent(event)
      if let client {
        scheduleGitHubTaskBoardRefresh(using: client)
      }
    case .taskBoardUpdated(let payload):
      applyGlobalPushEvent(event)
      let selection = Self.taskBoardPushRefreshSelection(scopes: payload.scopes)
      if let client, selection.hasWork {
        scheduleGitHubTaskBoardRefresh(
          using: client,
          includeItems: selection.items,
          includeOrchestratorStatus: selection.orchestratorStatus,
          includePolicyPipeline: selection.policyPipeline
        )
      }
    default:
      return false
    }
    return true
  }

  nonisolated static func taskBoardPushRefreshSelection(
    scopes: [String]
  ) -> TaskBoardPushRefreshSelection {
    let known = Set([
      "task_board:items",
      "task_board:machines",
      "task_board:orchestrator",
      "task_board:policy_pipeline",
      "task_board:policy_runtime",
      "task_board:runtime_config",
    ])
    let values = Set(scopes)
    let hasUnknown = values.isEmpty || !values.isSubset(of: known)
    return TaskBoardPushRefreshSelection(
      items: hasUnknown || values.contains("task_board:items"),
      orchestratorStatus: hasUnknown || values.contains("task_board:orchestrator"),
      policyPipeline: hasUnknown || values.contains("task_board:policy_pipeline")
    )
  }

  func recoverGitHubDataPushState(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence? = nil
  ) async {
    do {
      let githubStatus = try await client.githubStatus()
      guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return }
      if let revision = githubStatus.dataRevision,
        contentUI.dashboard.githubDataRevision != revision
      {
        contentUI.dashboard.latestGitHubDataChange = nil
        contentUI.dashboard.githubDataRevision = revision
      }
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect GitHub data refresh failed: \(err, privacy: .public)"
      )
    }
    do {
      let capabilities = try await client.taskBoardCapabilities()
      guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return }
      if capabilities.storage == "database",
        contentUI.dashboard.taskBoardRevision != capabilities.revision
      {
        contentUI.dashboard.taskBoardRevision = capabilities.revision
      }
    } catch {
      let err = error.localizedDescription
      HarnessMonitorLogger.store.warning(
        "websocket reconnect Task Board revision refresh failed: \(err, privacy: .public)"
      )
    }
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else { return }
    scheduleGitHubTaskBoardRefresh(
      using: client,
      includePolicyPipeline: true
    )
  }
}
