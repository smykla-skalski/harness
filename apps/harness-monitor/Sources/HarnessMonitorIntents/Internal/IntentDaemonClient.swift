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
  /// caller starts a fresh attempt
  ///
  /// The transport is created lazily in `init` and a fresh `URLSessionWebSocketTask`
  /// only exists after `connect()` runs. RPC methods therefore must call
  /// `ensureConnected()` before touching `transport` — otherwise the first
  /// `rpc()` returns `WebSocketTransportError.connectionClosed` because
  /// `webSocketTask` is still nil
  func ensureConnected() async throws {
    if let connectionTask {
      do {
        try await connectionTask.value
        return
      } catch {
        self.connectionTask = nil
        throw error
      }
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

  /// Drops the cached connection task so the next `ensureConnected()`
  /// runs a fresh connect+health probe. RPC methods call this from
  /// their catch block when the underlying WebSocket dies mid-flight,
  /// so a cached `IntentDaemonClient` can recover from daemon restarts
  /// without being rebuilt from scratch
  func invalidateConnection() {
    connectionTask = nil
  }

  /// Runs a leaf RPC body. Ensures the transport is connected first;
  /// on transport-level failures invalidates the cached connection so
  /// the next call reconnects; on application-level `IntentDaemonError`
  /// (e.g. validation throws like "Label must not be blank") passes
  /// the error through without disturbing the cache
  func runRPC<T: Sendable>(
    method: String,
    _ body: @Sendable () async throws -> T
  ) async throws -> T {
    do {
      try await ensureConnected()
      return try await body()
    } catch let error as IntentDaemonError {
      throw error
    } catch {
      invalidateConnection()
      throw IntentDaemonError.rpcFailed(
        method: method,
        message: error.localizedDescription
      )
    }
  }

  var hasActiveConnectionTaskForTesting: Bool { connectionTask != nil }

  func setConnectionTaskForTesting(_ task: Task<Void, Error>?) {
    self.connectionTask = task
  }
}
