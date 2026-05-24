import Foundation
import HarnessMonitorKit

/// Minimal abstraction over the daemon RPC that the count pump needs. Real
/// production code uses `IntentDaemonClient`; tests inject a fake.
public protocol DaemonCountClient: Sendable {
  func countNeedsMeReviewItems() async throws -> Int
}

extension IntentDaemonClient: DaemonCountClient {}

/// Resolves the needs-me count via the daemon RPC, caching the
/// `DaemonCountClient` (and its WebSocket) across calls. On any failure
/// the cache is invalidated so the next call rebuilds against a fresh
/// manifest — this matters when the daemon flaps during app launch and
/// the live-discovery resolver intermittently returns the unlaned path.
///
/// Without caching, every pump tick paid a fresh manifest read + token
/// read + WebSocket handshake (50-200ms each), and a 1-second daemon
/// discovery window was enough to make most ticks fail because the
/// discovery cache had expired but the daemon hadn't restamped yet.
public actor DaemonCountResolver {
  private let environment: HarnessMonitorEnvironment
  private let buildClient: @Sendable (HarnessMonitorEnvironment) throws -> DaemonCountClient
  private var cachedClient: DaemonCountClient?

  public init(environment: HarnessMonitorEnvironment = .current) {
    self.init(
      environment: environment,
      buildClient: { try IntentDaemonClient.resolveFromEnvironment(environment: $0) }
    )
  }

  init(
    environment: HarnessMonitorEnvironment,
    buildClient: @escaping @Sendable (HarnessMonitorEnvironment) throws -> DaemonCountClient
  ) {
    self.environment = environment
    self.buildClient = buildClient
  }

  public func resolve() async throws -> Int {
    let client = try acquireClient()
    do {
      return try await client.countNeedsMeReviewItems()
    } catch {
      cachedClient = nil
      throw error
    }
  }

  func invalidate() {
    cachedClient = nil
  }

  var hasCachedClient: Bool { cachedClient != nil }

  private func acquireClient() throws -> DaemonCountClient {
    if let cachedClient {
      return cachedClient
    }
    let fresh = try buildClient(environment)
    cachedClient = fresh
    return fresh
  }
}
