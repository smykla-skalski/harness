import Foundation

extension HarnessMonitorStore {
  func connectLive(
    using client: any HarnessMonitorClientProtocol,
    connectionFence: ConnectionAttemptFence
  ) async {
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
        await client.shutdown()
        return
      }
      await discardActiveConnection()
      await applyConnectionFailure(error)
      return
    }

    guard isCurrentConnectionAttemptFence(connectionFence) else {
      await client.shutdown()
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
