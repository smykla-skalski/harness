import Foundation

/// Memoizes a CloudKit record-zone creation so it runs at most once for the
/// lifetime of a database instance.
///
/// CloudKit zone creation is a *write*. Running it before every read turns each
/// fetch into a write-then-read round trip and piles avoidable traffic onto
/// CloudKit's write rate limiter, which is the dominant cause of mirror sync
/// timeouts. Writers still need the zone, so they call ``ensureIfNeeded()``;
/// the first call performs the write and every later call reuses its result.
/// Concurrent callers share the single in-flight operation rather than racing
/// to create the zone. ``invalidate()`` re-arms the ensurer after a
/// `.zoneNotFound` so a later write recreates the zone.
public actor MobileCloudMirrorZoneEnsurer {
  private let operation: @Sendable () async throws -> Void
  private var inFlight: Task<Void, any Error>?

  public init(operation: @escaping @Sendable () async throws -> Void) {
    self.operation = operation
  }

  public func ensureIfNeeded() async throws {
    if let inFlight {
      try await inFlight.value
      return
    }
    let task = Task { try await operation() }
    inFlight = task
    do {
      try await task.value
    } catch {
      inFlight = nil
      throw error
    }
  }

  public func invalidate() {
    inFlight = nil
  }
}
