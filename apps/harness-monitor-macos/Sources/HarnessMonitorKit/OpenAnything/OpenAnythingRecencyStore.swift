import Foundation
import Observation

/// Tracks recently-executed Open Anything records so the palette can bubble
/// frequently-used items to the top of the empty-query lane.
///
/// Persisted to UserDefaults under `OpenAnythingPreferencesDefaults.recencyKey`.
/// Capped at 20 entries; entries decay over a 30-day half-life so a user who
/// stops using a particular action sees it drift down naturally.
@MainActor
@Observable
public final class OpenAnythingRecencyStore {
  public struct Entry: Codable, Hashable, Sendable {
    public let recordID: String
    public let lastUsedAt: Date
    public let useCount: Int

    public init(recordID: String, lastUsedAt: Date, useCount: Int) {
      self.recordID = recordID
      self.lastUsedAt = lastUsedAt
      self.useCount = max(0, useCount)
    }
  }

  /// UserDefaults key used by the default initializer.
  public static let storageKey = "harness.openAnything.recency"

  /// Cap on persisted entries. Anything beyond this is trimmed by oldest first.
  public static let capacity = 20

  /// Half-life used by `score(for:now:)` to fade old entries.
  public static let halfLifeDays: Double = 30

  public private(set) var entries: [Entry]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let key: String

  public init(
    defaults: UserDefaults = .standard,
    key: String = OpenAnythingRecencyStore.storageKey
  ) {
    self.defaults = defaults
    self.key = key
    entries = Self.load(from: defaults, key: key)
  }

  /// Record that the user just executed the record with the given id.
  public func record(_ recordID: String, at date: Date = Date()) {
    var updated = entries.filter { $0.recordID != recordID }
    let previousCount = entries.first { $0.recordID == recordID }?.useCount ?? 0
    updated.insert(
      Entry(recordID: recordID, lastUsedAt: date, useCount: previousCount + 1),
      at: 0
    )
    if updated.count > Self.capacity {
      updated = Array(updated.prefix(Self.capacity))
    }
    entries = updated
    persist()
  }

  /// Drop every entry. Used by the Settings "Clear recency" affordance and
  /// by tests.
  public func clear() {
    guard !entries.isEmpty else { return }
    entries = []
    persist()
  }

  /// Ranked recency boost for `recordID`. Returns a non-negative value where
  /// higher means more recently / more frequently used. A record absent from
  /// the store returns 0.
  public func score(for recordID: String, now: Date = Date()) -> Double {
    guard let entry = entries.first(where: { $0.recordID == recordID }) else {
      return 0
    }
    let ageDays = max(0, now.timeIntervalSince(entry.lastUsedAt) / 86_400)
    let decay = pow(2.0, -ageDays / Self.halfLifeDays)
    return Double(entry.useCount) * decay
  }

  /// IDs in priority order (most recently used + decayed-frequency first).
  public func rankedIDs(now: Date = Date(), limit: Int = capacity) -> [String] {
    let scored = entries.map { ($0.recordID, score(for: $0.recordID, now: now)) }
    return
      scored
      .sorted { $0.1 > $1.1 }
      .prefix(limit)
      .map(\.0)
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(entries)
      defaults.set(data, forKey: key)
    } catch {
      // Persistence failure is non-fatal: in-memory state still works for
      // the current session.
    }
  }

  private static func load(from defaults: UserDefaults, key: String) -> [Entry] {
    guard let data = defaults.data(forKey: key) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }
}
