import Foundation

extension HarnessMonitorStore {
  private struct PreparedConnection: Sendable {
    let fence: ConnectionAttemptFence
  }

  func connect(using client: any HarnessMonitorClientProtocol) async throws {
    guard let prepared = try await prepareConnectionCandidate(using: client) else {
      return
    }
    self.client = client

    if maintainsLiveDaemonObservation {
      try await connectLive(using: client, connectionFence: prepared.fence)
      return
    }

    do {
      try await performPreviewConnectRefresh(
        using: client,
        preserveSelection: true,
        connectionFence: prepared.fence
      )
    } catch {
      guard isCurrentConnectionAttemptFence(prepared.fence) else {
        await settleAbandonedConnectionAttempt(using: client)
        return
      }
      guard await discardFailedConnectionUnlessReplaced() else {
        return
      }
      throw error
    }

    guard isCurrentConnectionAttemptFence(prepared.fence) else {
      await settleAbandonedConnectionAttempt(using: client)
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
      try await synchronizeConnectionCandidate(
        client,
        capabilities: capabilities,
        connectionFence: connectionFence
      )
    else {
      return nil
    }
    return PreparedConnection(fence: connectionFence)
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
  ) async throws -> Bool {
    let synchronizedCredentials = await syncStoredTaskBoardCredentialsForNewDaemon(
      using: client,
      validatedCapabilities: capabilities,
      accessFence: TaskBoardAccessFence(
        containment: connectionFence.containment,
        connection: connectionFence,
        databaseAccessGeneration: nil
      )
    )
    guard await retainCurrentConnectionCandidate(client, connectionFence: connectionFence) else {
      return false
    }
    guard synchronizedCredentials else {
      await client.shutdown()
      guard isCurrentConnectionAttemptFence(connectionFence) else {
        return false
      }
      if self.client === client {
        self.client = nil
      }
      throw HarnessMonitorAPIError.server(
        code: 503,
        message: "Task Board credential synchronization did not complete"
      )
    }
    return true
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
