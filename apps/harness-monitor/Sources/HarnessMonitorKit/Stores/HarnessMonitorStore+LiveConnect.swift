import Foundation

extension HarnessMonitorStore {
  func connectLive(
    using client: any HarnessMonitorClientProtocol,
    containmentFence: LegacyContainmentFence
  ) async {
    guard isCurrentLegacyContainmentFence(containmentFence) else {
      await client.shutdown()
      return
    }
    withUISyncBatch {
      connectionState = .connecting
    }

    let transport: TransportKind = client is WebSocketTransport ? .webSocket : .httpSSE
    resetConnectionMetrics(for: transport)

    do {
      try await performInitialConnectRefresh(using: client, preserveSelection: true)
    } catch {
      guard isCurrentLegacyContainmentFence(containmentFence) else {
        await client.shutdown()
        return
      }
      await discardActiveConnection()
      await applyConnectionFailure(error)
      return
    }

    guard isCurrentLegacyContainmentFence(containmentFence) else {
      await client.shutdown()
      return
    }
    withUISyncBatch {
      connectionState = .online
      markConnectionOnline()
    }
    appendConnectionEvent(kind: .connected, detail: connectedEventDetail(for: transport))
    startConnectionProbe(using: client)
    startManifestWatcher()
    startGlobalStream(using: client)
    if let selectedSessionID {
      startSessionStream(using: client, sessionID: selectedSessionID)
    } else {
      stopSessionStream()
    }
    scheduleSupervisorTick(reason: "connect-live")
  }
}
