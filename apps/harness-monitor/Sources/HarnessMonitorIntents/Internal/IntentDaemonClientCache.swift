import Foundation
import HarnessMonitorKit

/// Process-wide cache for `IntentDaemonClient`. Spotlight, Shortcuts
/// type-ahead, and Siri can fire several queries per second; without a
/// cache each one paid ~20-50ms for manifest read + WebSocket connect
/// + health probe. Caching across the TTL window cuts that to ~5ms
/// per follow-up call while leaving room for the daemon to flap
///
/// Single-slot cache because the App Intents process only ever talks
/// to one daemon (`HarnessMonitorEnvironment.current`). If a future
/// caller starts spanning environments, swap to a keyed dictionary
///
/// Sources call `client(for:)` instead of constructing directly, and
/// call `invalidate()` from their catch blocks when an RPC fails so
/// the next caller gets a fresh client against an up-to-date manifest
public actor IntentDaemonClientCache {
  public static let shared = IntentDaemonClientCache()

  private struct Entry {
    let client: IntentDaemonClient
    let expiresAt: Date
  }

  private var entry: Entry?
  private let ttl: TimeInterval
  private let now: @Sendable () -> Date
  private let clientBuilder: @Sendable (HarnessMonitorEnvironment) throws -> IntentDaemonClient

  public init(
    ttl: TimeInterval = 60,
    now: @escaping @Sendable () -> Date = { Date() },
    clientBuilder: @escaping @Sendable (HarnessMonitorEnvironment) throws -> IntentDaemonClient =
      { env in try IntentDaemonClient.resolveFromEnvironment(environment: env) }
  ) {
    self.ttl = ttl
    self.now = now
    self.clientBuilder = clientBuilder
  }

  /// Returns the cached client if still valid; otherwise builds a fresh
  /// one and caches it. Throws if the underlying builder fails (e.g.
  /// manifest missing or daemon not started)
  public func client(
    for environment: HarnessMonitorEnvironment = .current
  ) throws -> IntentDaemonClient {
    let timestamp = now()
    if let entry, timestamp < entry.expiresAt {
      return entry.client
    }
    let client = try clientBuilder(environment)
    entry = Entry(client: client, expiresAt: timestamp.addingTimeInterval(ttl))
    return client
  }

  /// Drops the cached client so the next `client(for:)` rebuilds. Call
  /// after any RPC failure so subsequent intents pick up daemon
  /// restarts and token rotation
  public func invalidate() {
    entry = nil
  }

  var hasCachedClientForTesting: Bool { entry != nil }
}
