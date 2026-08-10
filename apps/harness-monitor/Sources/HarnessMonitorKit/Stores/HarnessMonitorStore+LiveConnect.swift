import Foundation

extension HarnessMonitorStore {
  func connectLive(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async throws {
    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await client.shutdown()
      return
    }
    withUISyncBatch {
      connectionState = .connecting
    }

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)

    do {
      try await performInitialConnectRefresh(
        using: client,
        preserveSelection: true,
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
    guard await adoptConnectionCandidate(client, connectionFence: connectionFence) else {
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
