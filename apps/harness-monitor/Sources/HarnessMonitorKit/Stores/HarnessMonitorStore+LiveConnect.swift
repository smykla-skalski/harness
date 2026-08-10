import Foundation

extension HarnessMonitorStore {
  func connectLive(
    using client: any HarnessMonitorClientProtocol,
    preparedConnection: PreparedConnection
  ) async throws {
    let connectionFence = preparedConnection.fence
    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await client.shutdown()
      return
    }
    withUISyncBatch {
      connectionState = .connecting
    }

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)

    let preparedRefresh: PreparedRefreshApplication
    do {
      preparedRefresh = try await prepareInitialConnectRefresh(
        using: client,
        connectionFence: connectionFence
      )
    } catch {
      guard isCurrentConnectionAttemptFence(connectionFence) else {
        await settleAbandonedConnectionAttempt(using: client, connectionFence: connectionFence)
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

    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await settleAbandonedConnectionAttempt(using: client, connectionFence: connectionFence)
      return
    }
    let adopted = await adoptConnectionCandidate(
      client,
      connectionFence: connectionFence,
      onAdopt: {
        guard
          finishTaskBoardDatabaseSynchronization(
            preparedConnection.taskBoardSynchronization
          )
        else { return false }
        applyPreparedRefreshSnapshot(
          preparedRefresh,
          using: client,
          options: RefreshApplyOptions(
            preserveSelection: true,
            allowPreviewReadySelection: true,
            recordConnectionTelemetry: true,
            isInitialConnect: true,
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
      markConnectionOnline()
    }
    appendConnectionEvent(kind: .connected, detail: connectedEventDetail(for: transport))
    startConnectionProbe(using: client, connectionFence: connectionFence)
    startManifestWatcher()
    startGlobalStream(using: client, connectionFence: connectionFence)
    if let selectedSessionID {
      startSessionStream(using: client, sessionID: selectedSessionID)
    } else {
      stopSessionStream()
    }
    scheduleSupervisorTick(reason: "connect-live")
  }
}
