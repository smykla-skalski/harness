import Foundation

extension HarnessMonitorStore {
  func connectedEventDetail(for transport: TransportKind) -> String {
    "Connected via \(transport.title)"
  }

  func appendConnectionEvent(kind: ConnectionEventKind, detail: String) {
    guard maintainsLiveDaemonObservation else {
      return
    }
    let event = ConnectionEvent(kind: kind, detail: detail, transportKind: activeTransport)
    connectionEvents.append(event)
    if connectionEvents.count > 50 {
      connectionEvents.removeFirst(connectionEvents.count - 50)
    }
    switch kind {
    case .connected, .info:
      HarnessMonitorLogger.store.info("\(detail, privacy: .public)")
    case .disconnected, .error:
      HarnessMonitorLogger.store.warning("\(detail, privacy: .public)")
    case .reconnecting, .fallback:
      HarnessMonitorLogger.store.debug("\(detail, privacy: .public)")
    }
  }
}
