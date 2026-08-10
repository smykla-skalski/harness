import Foundation

public struct TaskBoardHostSnapshot: Equatable, Sendable {
  public let local: TaskBoardHostMachine
  public let registered: [TaskBoardHostMachine]

  public init(local: TaskBoardHostMachine, registered: [TaskBoardHostMachine]) {
    self.local = local
    self.registered = registered
  }
}

extension HarnessMonitorStore {
  public func taskBoardHostSnapshot() async throws -> TaskBoardHostSnapshot {
    let access = try await taskBoardHostClient()

    async let local = access.client.taskBoardHostLocal()
    async let registered = access.client.taskBoardHostList()

    let snapshot = try await TaskBoardHostSnapshot(local: local, registered: registered)
    try requireCurrentTaskBoardClientAccess(access)
    return snapshot
  }

  @discardableResult
  public func updateTaskBoardHostProjectTypes(_ projectTypes: [String]) async -> Bool {
    beginDaemonAction()
    defer { endDaemonAction() }

    do {
      let access = try await taskBoardHostClient()
      _ = try await access.client.setTaskBoardHostProjectTypes(
        request: TaskBoardHostSetProjectTypesRequest(projectTypes: projectTypes)
      )
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      presentSuccessFeedback("Updated host project types")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func taskBoardHostClient() async throws -> TaskBoardClientAccess {
    if let client {
      return try await requireCurrentDatabaseBackedTaskBoardClient(client)
    }
    await bootstrapIfNeeded()
    if let client {
      return try await requireCurrentDatabaseBackedTaskBoardClient(client)
    }
    return try await bootstrapSynchronizedTaskBoardClient()
  }
}
