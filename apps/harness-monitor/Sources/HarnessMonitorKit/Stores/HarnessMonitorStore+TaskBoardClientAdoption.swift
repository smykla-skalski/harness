import Foundation

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
  ) async throws -> any HarnessMonitorClientProtocol {
    let capabilities = try await withCurrentLegacyContainment {
      try await databaseBackedTaskBoardCapabilities(using: client)
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    return client
  }

  func bootstrapSynchronizedTaskBoardClient() async throws
    -> any HarnessMonitorClientProtocol
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
    return candidate
  }
}
