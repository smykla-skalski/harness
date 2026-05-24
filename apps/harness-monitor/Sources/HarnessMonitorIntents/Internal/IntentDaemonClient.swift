import Foundation
import HarnessMonitorKit

public actor IntentDaemonClient {
  public let transport: WebSocketTransport
  private var connectionTask: Task<Void, Error>?

  public init(connection: HarnessMonitorConnection) {
    self.transport = WebSocketTransport(connection: connection)
  }

  public static func resolveFromEnvironment(
    environment: HarnessMonitorEnvironment = .current
  ) throws -> IntentDaemonClient {
    let connection = try IntentConnectionResolver.resolve(environment: environment)
    return IntentDaemonClient(connection: connection)
  }

  /// Idempotently connects the underlying `WebSocketTransport` and verifies
  /// it with a health RPC. Concurrent callers coalesce onto the same
  /// in-flight attempt; on failure the cached task is dropped so the next
  /// caller starts a fresh attempt.
  ///
  /// The transport is created lazily in `init` and a fresh `URLSessionWebSocketTask`
  /// only exists after `connect()` runs. RPC methods therefore must call
  /// `ensureConnected()` before touching `transport` — otherwise the first
  /// `rpc()` returns `WebSocketTransportError.connectionClosed` because
  /// `webSocketTask` is still nil.
  func ensureConnected() async throws {
    if let connectionTask {
      try await connectionTask.value
      return
    }
    let task = Task { [transport] in
      try await transport.connect()
      _ = try await transport.health()
    }
    connectionTask = task
    do {
      try await task.value
    } catch {
      connectionTask = nil
      throw error
    }
  }

  var hasActiveConnectionTaskForTesting: Bool { connectionTask != nil }
}
