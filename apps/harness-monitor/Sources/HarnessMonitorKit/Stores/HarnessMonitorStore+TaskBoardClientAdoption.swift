import Foundation

struct TaskBoardClientAccess: Sendable {
  let client: any HarnessMonitorClientProtocol
  let instanceID: String
  let connectionFence: ConnectionAttemptFence
}

extension HarnessMonitorStore {
  func requireDatabaseBackedTaskBoard(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardCapabilities {
    taskBoardDatabaseInstanceID = nil
    let capabilities: TaskBoardCapabilities
    do {
      capabilities = try await databaseBackedTaskBoardCapabilities(using: client)
    } catch {
      taskBoardDatabaseInstanceID = nil
      throw error
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    return capabilities
  }

  func databaseBackedTaskBoardCapabilities(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardCapabilities {
    let capabilities = try await client.taskBoardCapabilities()
    guard capabilities.storage == "database" else {
      throw HarnessMonitorAPIError.server(
        code: 426,
        message: "Connected daemon does not provide a database-backed Task Board"
      )
    }
    guard !capabilities.instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw HarnessMonitorAPIError.server(
        code: 500,
        message: "Database-backed Task Board did not provide an instance identity"
      )
    }
    return capabilities
  }

  func adoptDatabaseBackedTaskBoard(_ capabilities: TaskBoardCapabilities) {
    noteConnectedDatabaseInstance(capabilities.instanceID)
    taskBoardDatabaseInstanceID = capabilities.instanceID
    contentUI.dashboard.taskBoardRevision = capabilities.revision
  }

  func requireCurrentDatabaseBackedTaskBoardClient(
    _ client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardClientAccess {
    let connectionFence = try currentConnectionAttemptFence()
    guard self.client === client else {
      throw CancellationError()
    }
    let capabilities = try await withCurrentLegacyContainment {
      try await databaseBackedTaskBoardCapabilities(using: client)
    }
    guard isCurrentTaskBoardClient(client, connectionFence: connectionFence) else {
      throw CancellationError()
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    return TaskBoardClientAccess(
      client: client,
      instanceID: capabilities.instanceID,
      connectionFence: connectionFence
    )
  }

  func bootstrapSynchronizedTaskBoardClient() async throws
    -> TaskBoardClientAccess
  {
    try await requireLegacyManagedLaunchAgentCleanupOrThrow()
    let connectionFence = try beginConnectionAttempt()
    let (candidate, capabilities) = try await withLegacyContainmentClient(
      { try await daemonController.bootstrapClient() },
      perform: { candidate in
        let capabilities = try await databaseBackedTaskBoardCapabilities(using: candidate)
        return (candidate, capabilities)
      }
    )
    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await candidate.shutdown()
      throw CancellationError()
    }
    let synchronized = await syncStoredTaskBoardCredentialsForNewDaemon(
      using: candidate,
      validatedCapabilities: capabilities,
      connectionFence: connectionFence
    )
    guard synchronized, isCurrentConnectionAttemptFence(connectionFence) else {
      await candidate.shutdown()
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Task Board credential synchronization did not complete"
      )
    }
    self.client = candidate
    return TaskBoardClientAccess(
      client: candidate,
      instanceID: capabilities.instanceID,
      connectionFence: connectionFence
    )
  }

  func requireCurrentTaskBoardClientAccess(_ access: TaskBoardClientAccess) throws {
    guard
      isCurrentTaskBoardClient(
        access.client,
        connectionFence: access.connectionFence
      ),
      taskBoardDatabaseInstanceID == access.instanceID
    else {
      throw CancellationError()
    }
  }

  private func isCurrentTaskBoardClient(
    _ client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) -> Bool {
    isCurrentConnectionAttemptFence(connectionFence) && self.client === client
  }
}
