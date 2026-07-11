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
    let client = try await taskBoardHostClient()

    async let local = client.taskBoardHostLocal()
    async let registered = client.taskBoardHostList()

    return try await TaskBoardHostSnapshot(local: local, registered: registered)
  }

  @discardableResult
  public func updateTaskBoardHostProjectTypes(_ projectTypes: [String]) async -> Bool {
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let client = try await taskBoardHostClient()
      _ = try await client.setTaskBoardHostProjectTypes(
        request: TaskBoardHostSetProjectTypesRequest(projectTypes: projectTypes)
      )
      recordRequestSuccess()
      presentSuccessFeedback("Updated host project types")
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func taskBoardHostClient() async throws -> any HarnessMonitorClientProtocol {
    if let client {
      _ = try await requireDatabaseBackedTaskBoard(using: client)
      return client
    }
    await bootstrapIfNeeded()
    if let client {
      _ = try await requireDatabaseBackedTaskBoard(using: client)
      return client
    }
    let bootstrappedClient = try await daemonController.bootstrapClient()
    _ = try await requireDatabaseBackedTaskBoard(using: bootstrappedClient)
    self.client = bootstrappedClient
    return bootstrappedClient
  }
}
