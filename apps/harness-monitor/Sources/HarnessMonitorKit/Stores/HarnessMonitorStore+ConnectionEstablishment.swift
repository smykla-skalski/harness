import Foundation

extension HarnessMonitorStore {
  struct PreparedConnection: Sendable {
    let fence: ConnectionAttemptFence
    let taskBoardSynchronization: PreparedTaskBoardDatabaseSynchronization
  }

  func connect(using client: any HarnessMonitorClientProtocol) async throws {
    guard let prepared = try await prepareConnectionCandidate(using: client) else {
      return
    }

    if maintainsLiveDaemonObservation {
      try await connectLive(using: client, preparedConnection: prepared)
      return
    }

    let preparedRefresh: PreparedRefreshApplication
    do {
      preparedRefresh = try await preparePreviewConnectRefresh(
        using: client,
        connectionFence: prepared.fence
      )
    } catch {
      guard isCurrentConnectionAttemptFence(prepared.fence) else {
        await settleAbandonedConnectionAttempt(using: client, connectionFence: prepared.fence)
        return
      }
      if self.client === client {
        guard await discardFailedConnectionUnlessReplaced() else {
          return
        }
      } else {
        await client.shutdown()
      }
      throw error
    }

    guard isCurrentConnectionAttemptFence(prepared.fence) else {
      await settleAbandonedConnectionAttempt(using: client, connectionFence: prepared.fence)
      return
    }
    let adopted = await adoptConnectionCandidate(
      client,
      connectionFence: prepared.fence,
      onAdopt: {
        guard finishTaskBoardDatabaseSynchronization(prepared.taskBoardSynchronization) else {
          return false
        }
        applyPreparedRefreshSnapshot(
          preparedRefresh,
          using: client,
          options: RefreshApplyOptions(
            preserveSelection: true,
            allowPreviewReadySelection: true,
            recordConnectionTelemetry: false,
            isInitialConnect: false,
            adoptsLocalManifest: !usesRemoteDaemon
          )
        )
        return true
      }
    )
    guard adopted else {
      return
    }
    withUISyncBatch {
      connectionState = .online
    }
  }

  private func prepareConnectionCandidate(
    using client: any HarnessMonitorClientProtocol
  ) async throws -> PreparedConnection? {
    let connectionFence = try await beginConnectionAttempt(for: client)
    guard
      let capabilities = try await loadConnectionCapabilities(
        using: client,
        connectionFence: connectionFence
      )
    else {
      return nil
    }
    await refreshPersistedSessionMetadata()
    guard await retainCurrentConnectionCandidate(client, connectionFence: connectionFence) else {
      return nil
    }
    guard
      let taskBoardSynchronization = try await synchronizeConnectionCandidate(
        client,
        capabilities: capabilities,
        connectionFence: connectionFence
      )
    else {
      return nil
    }
    return PreparedConnection(
      fence: connectionFence,
      taskBoardSynchronization: taskBoardSynchronization
    )
  }

  private func beginConnectionAttempt(
    for client: any HarnessMonitorClientProtocol
  ) async throws -> ConnectionAttemptFence {
    do {
      return try beginConnectionAttempt()
    } catch {
      await client.shutdown()
      throw error
    }
  }

  private func loadConnectionCapabilities(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async throws -> TaskBoardCapabilities? {
    let capabilities: TaskBoardCapabilities
    do {
      capabilities = try await databaseBackedTaskBoardCapabilities(using: client)
    } catch {
      await client.shutdown()
      guard isCurrentConnectionAttemptFence(connectionFence) else { return nil }
      if self.client === client {
        self.client = nil
      }
      throw error
    }
    guard await retainCurrentConnectionCandidate(client, connectionFence: connectionFence) else {
      return nil
    }
    return capabilities
  }

  private func synchronizeConnectionCandidate(
    _ client: any HarnessMonitorClientProtocol,
    capabilities: TaskBoardCapabilities,
    connectionFence: ConnectionAttemptFence
  ) async throws -> PreparedTaskBoardDatabaseSynchronization? {
    let synchronization = await prepareStoredTaskBoardCredentialsForNewDaemon(
      using: client,
      validatedCapabilities: capabilities,
      accessFence: TaskBoardAccessFence(
        containment: connectionFence.containment,
        connection: connectionFence,
        databaseAccessGeneration: nil
      )
    )
    guard await retainCurrentConnectionCandidate(client, connectionFence: connectionFence) else {
      return nil
    }
    guard let synchronization else {
      await client.shutdown()
      guard isCurrentConnectionAttemptFence(connectionFence) else {
        return nil
      }
      if self.client === client {
        self.client = nil
      }
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Task Board credential synchronization did not complete"
      )
    }
    return synchronization
  }

  private func retainCurrentConnectionCandidate(
    _ client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async -> Bool {
    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await client.shutdown()
      return false
    }
    return true
  }

}
