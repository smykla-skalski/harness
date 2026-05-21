import Foundation

/// Per-user persistence for dependency update PR description bodies.
///
/// Keyed by GitHub PR node id. Each entry stores the markdown body plus the
/// PR's `updatedAt` at fetch time so the cache can be invalidated when the
/// PR itself has been edited or commented on since the cached fetch.
public final class DependencyUpdateBodyStore: @unchecked Sendable {
  public static let defaultsKey = "HarnessMonitor.Dependencies.PullRequestBodies"

  public struct Entry: Codable, Equatable, Sendable {
    public let body: String
    public let prUpdatedAt: String
    public let fetchedAt: String

    public init(body: String, prUpdatedAt: String, fetchedAt: String) {
      self.body = body
      self.prUpdatedAt = prUpdatedAt
      self.fetchedAt = fetchedAt
    }
  }

  private struct Payload: Codable, Equatable {
    var entries: [String: Entry] = [:]
  }

  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()
  private static let persistQueue = DispatchQueue(
    label: "io.harnessmonitor.dependency-update-bodies.persist",
    qos: .utility
  )

  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()
  private var cachedPayload: Payload?

  public init(
    defaults: UserDefaults = .standard,
    key: String = DependencyUpdateBodyStore.defaultsKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  /// Returns the cached entry only if it is fresh relative to the supplied
  /// `prUpdatedAt`. If the PR has been updated since the cached fetch (or no
  /// entry exists), returns nil so the caller refetches.
  public func cached(forPullRequestID id: String, since prUpdatedAt: String) -> Entry? {
    let payload = load()
    guard let entry = payload.entries[id] else { return nil }
    return entry.prUpdatedAt >= prUpdatedAt ? entry : nil
  }

  /// Returns the cached entry without staleness check. Used by tests and by
  /// the loading path before the daemon has reported a fresh `updated_at`.
  public func cached(forPullRequestID id: String) -> Entry? {
    load().entries[id]
  }

  public func store(
    pullRequestID id: String,
    body: String,
    prUpdatedAt: String,
    fetchedAt: String
  ) {
    update { payload in
      payload.entries[id] = Entry(
        body: body,
        prUpdatedAt: prUpdatedAt,
        fetchedAt: fetchedAt
      )
    }
  }

  public func clear() {
    lock.lock()
    cachedPayload = Payload()
    lock.unlock()
    Self.persistQueue.async { [self] in
      defaults.removeObject(forKey: key)
    }
  }

  private func load() -> Payload {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cachedPayload {
      return cached
    }
    let payload: Payload
    if let data = defaults.data(forKey: key),
      let decoded = try? Self.decoder.decode(Payload.self, from: data)
    {
      payload = decoded
    } else {
      payload = Payload()
    }
    cachedPayload = payload
    return payload
  }

  private func update(_ mutate: (inout Payload) -> Void) {
    lock.lock()
    var payload =
      cachedPayload
      ?? {
        if let data = defaults.data(forKey: key),
          let decoded = try? Self.decoder.decode(Payload.self, from: data)
        {
          return decoded
        }
        return Payload()
      }()
    mutate(&payload)
    cachedPayload = payload
    let payloadCopy = payload
    lock.unlock()
    Self.persistQueue.async { [self] in
      if let encoded = try? Self.encoder.encode(payloadCopy) {
        defaults.set(encoded, forKey: key)
      }
    }
  }
}
