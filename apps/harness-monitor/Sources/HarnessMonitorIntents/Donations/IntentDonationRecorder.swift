import Foundation

/// Discriminator for the entity kind a donation belongs to. Sources query
/// `recentIDs(kind:)` to bias their own surface without interleaving
/// unrelated kinds. Adding a new kind requires both producers (the donate
/// helpers in `HarnessMonitorIntentDonations`) and consumers (the matching
/// `*Query.suggestedEntities`) to be wired in the same change
public enum IntentDonationKind: String, Codable, Sendable, CaseIterable {
  case pullRequest
  case taskBoardItem
  case repository
}

/// Tracks the most-recent IDs the user has acted on via App Intents.
/// Spotlight, the Shortcuts editor, and Siri query each surface's
/// `*Query.suggestedEntities`; we sort donated IDs to the front so the
/// entity the user touched 30 seconds ago is the first hit
///
/// Donations persist in the shared App Group `UserDefaults`
/// (`Q498EB36N4.io.harnessmonitor`) so a donation recorded by the Mac
/// host process surfaces in the Intent extension and Spotlight processes
/// without an IPC round-trip. Each kind keeps its own ring buffer
/// (default capacity 20) so a burst of one kind cannot evict another
public actor IntentDonationRecorder {
  public static let shared = IntentDonationRecorder()

  public static let defaultSuiteName = "Q498EB36N4.io.harnessmonitor"
  public static let defaultStorageKey = "io.harnessmonitor.intents.donations.v1"

  private struct Entry: Codable, Equatable, Sendable {
    let kind: IntentDonationKind
    let id: String
    let timestamp: Date
  }

  private let capacityPerKind: Int
  private let now: @Sendable () -> Date
  private let defaults: UserDefaults?
  private let storageKey: String

  public init(
    capacity: Int = 20,
    now: @escaping @Sendable () -> Date = { Date() },
    defaults: UserDefaults? = UserDefaults(suiteName: IntentDonationRecorder.defaultSuiteName),
    storageKey: String = IntentDonationRecorder.defaultStorageKey
  ) {
    self.capacityPerKind = max(1, capacity)
    self.now = now
    self.defaults = defaults
    self.storageKey = storageKey
  }

  /// Records a donation for the given kind. Duplicate `(kind, id)` pairs
  /// move to the most-recent slot rather than accumulating; entries past
  /// the per-kind capacity evict oldest-first
  public func recordDonation(kind: IntentDonationKind, id: String) {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var entries = load()
    entries.removeAll { $0.kind == kind && $0.id == trimmed }
    entries.append(Entry(kind: kind, id: trimmed, timestamp: now()))
    entries = trim(entries, kind: kind)
    save(entries)
  }

  /// Returns the donated IDs for the given kind, newest-first
  public func recentIDs(kind: IntentDonationKind) -> [String] {
    load()
      .filter { $0.kind == kind }
      .reversed()
      .map(\.id)
  }

  /// Legacy convenience routing to `.pullRequest`. Pre-existing callers
  /// stay source-compatible until they're migrated to the kind-aware API
  public func recordDonation(pullRequestID id: String) {
    recordDonation(kind: .pullRequest, id: id)
  }

  /// Legacy convenience routing to `.pullRequest`
  public func recentIDs() -> [String] {
    recentIDs(kind: .pullRequest)
  }

  /// Wipes the recorder. Test seam plus a manual escape hatch for
  /// "Forget what I clicked" UX if we ever ship it
  public func clear() {
    defaults?.removeObject(forKey: storageKey)
  }

  var countForTesting: Int { load().count }

  // MARK: - Persistence

  private func load() -> [Entry] {
    guard let defaults, let data = defaults.data(forKey: storageKey) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  private func save(_ entries: [Entry]) {
    guard let defaults else { return }
    if entries.isEmpty {
      defaults.removeObject(forKey: storageKey)
      return
    }
    guard let data = try? JSONEncoder().encode(entries) else { return }
    defaults.set(data, forKey: storageKey)
  }

  /// Drops the oldest entries of `kind` so the per-kind count stays at or
  /// below `capacityPerKind`. Entries of other kinds are untouched
  private func trim(_ entries: [Entry], kind: IntentDonationKind) -> [Entry] {
    let sameKindIndices = entries.enumerated()
      .compactMap { $0.element.kind == kind ? $0.offset : nil }
    guard sameKindIndices.count > capacityPerKind else { return entries }
    let overflow = sameKindIndices.count - capacityPerKind
    let dropIndices = Set(sameKindIndices.prefix(overflow))
    return entries.enumerated()
      .compactMap { dropIndices.contains($0.offset) ? nil : $0.element }
  }
}
