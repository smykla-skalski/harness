import Foundation

public struct OpenRouterModelUsageSnapshot: Equatable, Sendable {
  public static let empty = Self()

  public let pinned: [String]
  public let recents: [String]
  public let frequencies: [String: Int]
  private let pinnedLookup: Set<String>

  public init(
    pinned: [String] = [],
    recents: [String] = [],
    frequencies: [String: Int] = [:]
  ) {
    self.pinned = pinned
    self.recents = recents
    self.frequencies = frequencies
    pinnedLookup = Set(pinned)
  }

  public func recentModels(limit: Int = OpenRouterModelUsageStore.recentLimit) -> [String] {
    Array(recents.prefix(max(0, limit)))
  }

  public func frequentModels(limit: Int = OpenRouterModelUsageStore.recentLimit) -> [String] {
    frequencies
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(max(0, limit))
      .map(\.key)
  }

  public func isPinned(_ modelID: String) -> Bool {
    pinnedLookup.contains(modelID)
  }
}

/// Per-user persistence for OpenRouter model selection state shown in the new
/// agent picker. Tracks three independent dimensions:
///
/// - `pinned`: unbounded set of model ids the user explicitly pinned.
/// - `recents`: ordered list of model ids most recently used to start or
///   prompt an OpenRouter run, capped at `recentLimit`.
/// - `frequencies`: usage count per model id, used to surface a "frequently
///   used" section in the picker.
///
/// All data lives in `UserDefaults` under a single JSON-encoded key so future
/// schema changes can stay backward compatible.
public final class OpenRouterModelUsageStore: @unchecked Sendable {
  public static let defaultsKey = "HarnessMonitor.OpenRouter.ModelUsage"
  public static let recentLimit = 5

  private struct Payload: Codable, Equatable {
    var pinned: [String] = []
    var recents: [String] = []
    var frequencies: [String: Int] = [:]

    var snapshot: OpenRouterModelUsageSnapshot {
      OpenRouterModelUsageSnapshot(
        pinned: pinned,
        recents: recents,
        frequencies: frequencies
      )
    }
  }

  private static let decoder = JSONDecoder()
  private static let encoder = JSONEncoder()

  private let defaults: UserDefaults
  private let key: String
  private let lock = NSLock()
  private var cachedPayload: Payload?

  public init(
    defaults: UserDefaults = .standard, key: String = OpenRouterModelUsageStore.defaultsKey
  ) {
    self.defaults = defaults
    self.key = key
  }

  public func pinnedModels() -> [String] {
    load().pinned
  }

  public func recentModels(limit: Int = OpenRouterModelUsageStore.recentLimit) -> [String] {
    Array(load().recents.prefix(max(0, limit)))
  }

  public func frequentModels(limit: Int = OpenRouterModelUsageStore.recentLimit) -> [String] {
    let payload = load()
    return payload.frequencies
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key < rhs.key
      }
      .prefix(max(0, limit))
      .map(\.key)
  }

  public func isPinned(_ modelID: String) -> Bool {
    load().pinned.contains(modelID)
  }

  public func snapshot() -> OpenRouterModelUsageSnapshot {
    load().snapshot
  }

  public func togglePin(_ modelID: String) {
    update { payload in
      if let index = payload.pinned.firstIndex(of: modelID) {
        payload.pinned.remove(at: index)
      } else {
        payload.pinned.append(modelID)
      }
    }
  }

  public func recordUsage(of modelID: String, now: Date = Date()) {
    let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    update { payload in
      payload.recents.removeAll { $0 == trimmed }
      payload.recents.insert(trimmed, at: 0)
      let capacity = Self.recentLimit
      if payload.recents.count > capacity {
        payload.recents = Array(payload.recents.prefix(capacity))
      }
      payload.frequencies[trimmed, default: 0] += 1
      _ = now
    }
  }

  public func reset() {
    lock.lock()
    defer { lock.unlock() }
    defaults.removeObject(forKey: key)
    cachedPayload = Payload()
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
    defer { lock.unlock() }
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
    if let encoded = try? Self.encoder.encode(payload) {
      defaults.set(encoded, forKey: key)
    }
  }
}
