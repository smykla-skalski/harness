import Foundation

struct TaskBoardAccessFence: Sendable {
  let containment: LegacyContainmentFence
  let connection: ConnectionAttemptFence?
  let databaseAccessGeneration: UInt64?
}

struct TaskBoardClientAccess: Sendable {
  let client: any HarnessMonitorClientProtocol
  let instanceID: String
  let connectionFence: ConnectionAttemptFence
  let databaseAccessGeneration: UInt64

  var accessFence: TaskBoardAccessFence {
    TaskBoardAccessFence(
      containment: connectionFence.containment,
      connection: connectionFence,
      databaseAccessGeneration: databaseAccessGeneration
    )
  }
}

private struct TaskBoardSourceSyncQuiescenceError: LocalizedError {
  let errorDescription: String?

  init(_ description: String) {
    errorDescription = description
  }
}

extension HarnessMonitorStore {
  var availableTaskBoardClient: (any HarnessMonitorClientProtocol)? {
    guard taskBoardRuntimeState.connection.databaseAccessSuspended == false else {
      return nil
    }
    return client
  }

  var availableTaskBoardClientAccess: TaskBoardClientAccess? {
    guard
      let client = availableTaskBoardClient,
      let instanceID = taskBoardDatabaseInstanceID,
      let connectionFence = try? currentConnectionAttemptFence()
    else {
      return nil
    }
    return TaskBoardClientAccess(
      client: client,
      instanceID: instanceID,
      connectionFence: connectionFence,
      databaseAccessGeneration: taskBoardRuntimeState.connection.databaseAccessGeneration
    )
  }

  func requireDatabaseBackedTaskBoard(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> TaskBoardCapabilities {
    guard taskBoardRuntimeState.connection.databaseAccessSuspended == false else {
      throw CancellationError()
    }
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
    let databaseAccessGeneration = taskBoardRuntimeState.connection.databaseAccessGeneration
    guard
      taskBoardRuntimeState.connection.databaseAccessSuspended == false,
      self.client === client
    else {
      throw CancellationError()
    }
    let capabilities = try await withCurrentLegacyContainment {
      try await databaseBackedTaskBoardCapabilities(using: client)
    }
    guard
      isCurrentTaskBoardClient(client, connectionFence: connectionFence),
      taskBoardRuntimeState.connection.databaseAccessSuspended == false,
      isCurrentTaskBoardDatabaseAccessGeneration(databaseAccessGeneration)
    else {
      throw CancellationError()
    }
    adoptDatabaseBackedTaskBoard(capabilities)
    return TaskBoardClientAccess(
      client: client,
      instanceID: capabilities.instanceID,
      connectionFence: connectionFence,
      databaseAccessGeneration: databaseAccessGeneration
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
      accessFence: TaskBoardAccessFence(
        containment: connectionFence.containment,
        connection: connectionFence,
        databaseAccessGeneration: nil
      )
    )
    guard synchronized, isCurrentConnectionAttemptFence(connectionFence) else {
      await candidate.shutdown()
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Task Board credential synchronization did not complete"
      )
    }
    guard await adoptConnectionCandidate(candidate, connectionFence: connectionFence) else {
      throw CancellationError()
    }
    return TaskBoardClientAccess(
      client: candidate,
      instanceID: capabilities.instanceID,
      connectionFence: connectionFence,
      databaseAccessGeneration: taskBoardRuntimeState.connection.databaseAccessGeneration
    )
  }

  func requireCurrentTaskBoardClientAccess(_ access: TaskBoardClientAccess) throws {
    guard
      isCurrentTaskBoardClient(
        access.client,
        connectionFence: access.connectionFence
      ),
      taskBoardDatabaseInstanceID == access.instanceID,
      taskBoardRuntimeState.connection.databaseAccessSuspended == false,
      isCurrentTaskBoardDatabaseAccessGeneration(access.databaseAccessGeneration)
    else {
      throw CancellationError()
    }
  }

  @discardableResult
  func invalidateTaskBoardDatabaseAccess(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence? = nil
  ) async throws -> UInt64 {
    taskBoardRuntimeState.connection.databaseAccessGeneration &+= 1
    await supervisorStack?.registry.advanceOverrideSourceGeneration(
      to: taskBoardRuntimeState.connection.databaseAccessGeneration
    )
    taskBoardRuntimeState.connection.databaseAccessSuspended = true
    taskBoardDatabaseInstanceID = nil
    lastTaskBoardCredentialSync = nil
    cancelTaskBoardDashboardSnapshotRefresh()
    scheduleUISync([.contentDashboard])
    try await quiesceTaskBoardSourceSync(using: client, connectionFence: connectionFence)
    return taskBoardRuntimeState.connection.databaseAccessGeneration
  }

  private func quiesceTaskBoardSourceSync(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence?
  ) async throws {
    let restoreIdlePhase = taskBoardSyncPhase == .idle
    defer {
      if restoreIdlePhase {
        setTaskBoardSyncPhase(.idle)
      }
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while true {
      let statusTimeout = try taskBoardSourceSyncRecoveryTimeout(
        deadline: deadline,
        connectionFence: connectionFence
      )
      let status = try await client.taskBoardSyncStatus(recoveryTimeout: statusTimeout)
      _ = try taskBoardSourceSyncRecoveryTimeout(
        deadline: deadline,
        connectionFence: connectionFence
      )
      guard status.active else { return }
      setTaskBoardSyncPhase(.stopping)
      if !status.cancellationRequested {
        let cancelTimeout = try taskBoardSourceSyncRecoveryTimeout(
          deadline: deadline,
          connectionFence: connectionFence
        )
        _ = try await client.cancelTaskBoardSync(recoveryTimeout: cancelTimeout)
        _ = try taskBoardSourceSyncRecoveryTimeout(
          deadline: deadline,
          connectionFence: connectionFence
        )
      }
      let sleepBudget = try taskBoardSourceSyncRecoveryTimeout(
        deadline: deadline,
        connectionFence: connectionFence
      )
      try await Task.sleep(for: min(.milliseconds(250), sleepBudget))
    }
  }

  private func taskBoardSourceSyncRecoveryTimeout(
    deadline: ContinuousClock.Instant,
    connectionFence: ConnectionAttemptFence?
  ) throws -> Duration {
    try Task.checkCancellation()
    guard isCurrentConnectionAttemptFenceIfProvided(connectionFence) else {
      throw CancellationError()
    }
    let remaining = ContinuousClock.now.duration(to: deadline)
    guard remaining > .zero else {
      throw TaskBoardSourceSyncQuiescenceError(
        "Task source refresh did not stop before database recovery"
      )
    }
    return min(remaining, .seconds(5))
  }

  func isCurrentTaskBoardDatabaseAccessGeneration(_ generation: UInt64) -> Bool {
    generation == taskBoardRuntimeState.connection.databaseAccessGeneration
  }

  func completeTaskBoardDatabaseSynchronization(
    _ capabilities: TaskBoardCapabilities,
    accessFence: TaskBoardAccessFence
  ) -> Bool {
    guard isCurrentTaskBoardAccessFence(accessFence) else { return false }
    adoptDatabaseBackedTaskBoard(capabilities)
    taskBoardRuntimeState.connection.databaseAccessSuspended = false
    scheduleUISync([.contentDashboard])
    return true
  }

  private func isCurrentTaskBoardClient(
    _ client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) -> Bool {
    isCurrentConnectionAttemptFence(connectionFence) && self.client === client
  }
}
