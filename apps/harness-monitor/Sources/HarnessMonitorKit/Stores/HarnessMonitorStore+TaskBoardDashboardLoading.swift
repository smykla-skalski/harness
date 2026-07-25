import Foundation

extension HarnessMonitorStore {
  struct TaskBoardSnapshotLoad<Value: Sendable>: Sendable {
    let measured: MeasuredOperation<Value>?

    var value: Value? { measured?.value }
  }

  struct TaskBoardRefreshSnapshot: Sendable {
    let items: TaskBoardSnapshotLoad<[TaskBoardItem]>
    let orchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>
    let projects: TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>
    let stepModeConfirmationRevision: UInt64
  }

  static let taskBoardDashboardSyncRequest = TaskBoardSyncRequest(
    direction: .pull,
    dryRun: false
  )
  static let taskBoardDashboardRefreshActivityKey = "task-board-dashboard-refresh"

  nonisolated static func loadTaskBoardItemsSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardSnapshotLoad<[TaskBoardItem]> {
    do {
      return TaskBoardSnapshotLoad(
        measured: try await measureOperation {
          try await client.taskBoardItems(status: nil)
        }
      )
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board snapshot unavailable during refresh: \(description, privacy: .public)"
      )
      return TaskBoardSnapshotLoad(measured: nil)
    }
  }

  /// The catalog every card's project mark reads. It rides the board refresh
  /// rather than a screen's own load, so a card is marked before anyone opens
  /// Settings, and a color changed elsewhere lands on the next refresh.
  nonisolated static func loadTaskBoardProjectsSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardSnapshotLoad<[TaskBoardProjectSummary]> {
    do {
      return TaskBoardSnapshotLoad(
        measured: try await measureOperation {
          try await client.taskBoardProjects(status: nil)
        }
      )
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board projects snapshot unavailable during refresh: \(description, privacy: .public)"
      )
      return TaskBoardSnapshotLoad(measured: nil)
    }
  }

  nonisolated static func loadTaskBoardOrchestratorStatusSnapshot(
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?> {
    do {
      return TaskBoardSnapshotLoad(
        measured: try await measureOperation {
          try await client.taskBoardOrchestratorStatus()
        }
      )
    } catch {
      let description = RefreshSnapshotErrorFormatting.describeUnderlying(error)
      HarnessMonitorLogger.store.debug(
        "task-board orchestrator snapshot unavailable during refresh: \(description, privacy: .public)"
      )
      return TaskBoardSnapshotLoad(measured: nil)
    }
  }

  nonisolated static func loadTaskBoardRefreshSnapshot(
    using client: any HarnessMonitorClientProtocol,
    stepModeConfirmationRevision: UInt64,
    includeItems: Bool = true,
    includeOrchestratorStatus: Bool = true
  ) async -> TaskBoardRefreshSnapshot {
    async let items =
      if includeItems {
        loadTaskBoardItemsSnapshot(using: client)
      } else {
        TaskBoardSnapshotLoad<[TaskBoardItem]>(measured: nil)
      }
    async let orchestratorStatus =
      if includeOrchestratorStatus {
        loadTaskBoardOrchestratorStatusSnapshot(using: client)
      } else {
        TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>(measured: nil)
      }
    async let projects =
      if includeItems {
        loadTaskBoardProjectsSnapshot(using: client)
      } else {
        TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>(measured: nil)
      }
    return TaskBoardRefreshSnapshot(
      items: await items,
      orchestratorStatus: await orchestratorStatus,
      projects: await projects,
      stepModeConfirmationRevision: stepModeConfirmationRevision
    )
  }
}
