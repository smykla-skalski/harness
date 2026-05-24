import Foundation

extension HarnessMonitorStore {
  func reconnectDelay(for attempt: Int) -> Duration {
    Self.streamReconnectDelays[min(attempt, Self.streamReconnectDelays.count - 1)]
  }

  /// True when `error` means the WebSocket transport has been torn down
  /// (the `webSocketTask` is nil or the actor was shut down). The store's
  /// stream loops short-circuit on this so they do not burn the full
  /// `streamReconnectMaxAttempts` backoff against a transport that the
  /// receive loop has already abandoned.
  static func isTransportClosedError(_ error: any Error) -> Bool {
    if case WebSocketTransportError.connectionClosed = error {
      return true
    }
    return false
  }
}
