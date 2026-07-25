import Foundation

/// Per-repository view of an in-flight working-copy obtain, assembled from the
/// daemon's progress events.
///
/// The daemon emits on a fixed interval even when the counts have not moved, so
/// "advancing" and "stalled" are distinguished by whether `done` changed, not by
/// whether events arrived. Silence means the daemon stopped reporting, which is
/// itself a stall rather than progress.
///
/// Time is injected rather than read, so the stall rule is testable without
/// waiting for it.
public struct TaskBoardWorkingCopyProgressTracker: Equatable, Sendable {
  /// How long the counts may sit unchanged before the obtain reads as stalled.
  /// Well above the daemon's sampling interval, so an ordinary slow tick is not
  /// mistaken for a stall.
  public static let stallThreshold: TimeInterval = 5

  public struct Entry: Equatable, Sendable {
    public let progress: TaskBoardWorkingCopyProgress
    /// When `done` last changed, or when the obtain started for a phase that has
    /// not counted yet.
    public let lastAdvancedAt: Date

    /// Public so previews and other modules can build a fixed entry; the
    /// tracker itself is what builds them at runtime.
    public init(progress: TaskBoardWorkingCopyProgress, lastAdvancedAt: Date) {
      self.progress = progress
      self.lastAdvancedAt = lastAdvancedAt
    }

    // Qualified: a nested type does not see the enclosing type's statics
    // through unqualified lookup.
    public func isStalled(
      now: Date,
      threshold: TimeInterval = TaskBoardWorkingCopyProgressTracker.stallThreshold
    ) -> Bool {
      if progress.blocked { return true }
      guard progress.isInFlight else { return false }
      return now.timeIntervalSince(lastAdvancedAt) >= threshold
    }
  }

  private var entries: [String: Entry] = [:]

  public init() {}

  /// Fold one event in. Terminal events drop the entry, returning the row to its
  /// resolved or retry state, which is what the caller renders when this returns
  /// nil for a repo.
  public mutating func ingest(_ progress: TaskBoardWorkingCopyProgress, at now: Date) {
    guard progress.isInFlight else {
      entries.removeValue(forKey: progress.repoFullName)
      return
    }
    let previous = entries[progress.repoFullName]
    let advanced = previous.map { $0.progress.done != progress.done } ?? true
    entries[progress.repoFullName] = Entry(
      progress: progress,
      lastAdvancedAt: advanced ? now : (previous?.lastAdvancedAt ?? now)
    )
  }

  public func entry(for repoFullName: String) -> Entry? {
    entries[repoFullName]
  }

  /// Whether an obtain for this repository is in flight, so a caller can keep
  /// showing progress without reaching for the entry's fields.
  public func isObtaining(_ repoFullName: String) -> Bool {
    entries[repoFullName] != nil
  }

  /// Forget a repository, for a caller that gave up on an obtain it started
  /// without ever receiving a terminal event.
  public mutating func forget(_ repoFullName: String) {
    entries.removeValue(forKey: repoFullName)
  }
}
