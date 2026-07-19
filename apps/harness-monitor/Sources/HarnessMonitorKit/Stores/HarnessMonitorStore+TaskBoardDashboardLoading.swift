import Foundation

extension HarnessMonitorStore {
  struct TaskBoardSnapshotLoad<Value: Sendable>: Sendable {
    let measured: MeasuredOperation<Value>?

    var value: Value? { measured?.value }
  }

  struct TaskBoardRefreshSnapshot: Sendable {
    let items: TaskBoardSnapshotLoad<[TaskBoardItem]>
    let orchestratorStatus: TaskBoardSnapshotLoad<TaskBoardOrchestratorStatus?>
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
    return TaskBoardRefreshSnapshot(
      items: await items,
      orchestratorStatus: await orchestratorStatus,
      stepModeConfirmationRevision: stepModeConfirmationRevision
    )
  }
}
