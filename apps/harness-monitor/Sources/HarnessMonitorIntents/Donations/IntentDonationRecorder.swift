import Foundation

/// Tracks the most-recent pull-request IDs the user has acted on via
/// App Intents (Approve, Merge, AddLabel, RerunChecks). Spotlight and
/// the Shortcuts editor query `PullRequestQuery.suggestedEntities` for
/// the top picks; we sort donated IDs to the front so the PR the user
/// touched 30 seconds ago is the first hit
///
/// The recorder is a tiny in-memory ring buffer (max 20 entries) keyed
/// in insertion order. Lives for the lifetime of the host process; the
/// intent extension and main app each maintain their own copy because
/// donation order is short-term context, not persistent history
public actor IntentDonationRecorder {
  public static let shared = IntentDonationRecorder()

  private struct Entry {
    let id: String
    let timestamp: Date
  }

  private var entries: [Entry] = []
  private let capacity: Int
  private let now: @Sendable () -> Date

  public init(
    capacity: Int = 20,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.capacity = max(1, capacity)
    self.now = now
  }

  /// Records that the user just donated an intent for the given pull
  /// request ID. Duplicate IDs move to the most-recent slot rather
  /// than accumulating
  public func recordDonation(pullRequestID id: String) {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    entries.removeAll { $0.id == trimmed }
    entries.append(Entry(id: trimmed, timestamp: now()))
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  /// Returns the donated IDs newest-first. Sources call this from
  /// `suggestedEntities` to bias the order they return to Spotlight
  public func recentIDs() -> [String] {
    entries.reversed().map(\.id)
  }

  /// Wipes the recorder. Test seam plus a manual escape hatch for
  /// "Forget what I clicked" UX if we ever ship it
  public func clear() {
    entries.removeAll()
  }

  var countForTesting: Int { entries.count }
}
