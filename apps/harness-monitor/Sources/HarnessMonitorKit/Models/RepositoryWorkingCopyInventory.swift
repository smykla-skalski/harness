import Foundation

/// Splits the working copies the daemon holds into the ones a monitored
/// repository row already offers to reclaim and the ones no such row shows.
///
/// A working copy outlives the reason it was obtained: dropping the repository
/// from the monitored list, or pointing it at a folder the user picked instead,
/// leaves the checkout on disk with no control anywhere in Settings. Until the
/// daemon's garbage collection eventually evicted it, that disk was neither
/// visible nor reclaimable.
public struct RepositoryWorkingCopyInventory: Equatable, Sendable {
  /// Every copy keyed by normalized repository, for the per-repository rows.
  public let byRepository: [String: WorkingCopyListEntry]

  /// The copies no per-repository row can reclaim, largest first so a disk
  /// audit reads top down.
  public let unlisted: [WorkingCopyListEntry]

  public init(
    copies: [WorkingCopyListEntry],
    monitoredRepositories: [String],
    associatedRepositories: Set<String>
  ) {
    let monitored = Set(monitoredRepositories.map(Self.normalized))
    let associated = Set(associatedRepositories.map(Self.normalized))
    byRepository = Dictionary(
      copies.map { (Self.normalized($0.repoFullName), $0) },
      uniquingKeysWith: { first, _ in first }
    )
    // A monitored repository bound to a picked folder shows Remove rather than
    // Reclaim, so its copy is as hidden as an unmonitored one.
    unlisted =
      copies
      .filter { copy in
        let key = Self.normalized(copy.repoFullName)
        return !monitored.contains(key) || associated.contains(key)
      }
      .sorted(by: Self.largestFirst)
  }

  private static func largestFirst(
    _ lhs: WorkingCopyListEntry,
    _ rhs: WorkingCopyListEntry
  ) -> Bool {
    if lhs.sizeBytes != rhs.sizeBytes {
      return lhs.sizeBytes > rhs.sizeBytes
    }
    if lhs.repoFullName != rhs.repoFullName {
      return lhs.repoFullName < rhs.repoFullName
    }
    return lhs.repoKeySegment < rhs.repoKeySegment
  }

  private static func normalized(_ repository: String) -> String {
    RepositoryDirectoryStore.normalizedRepository(repository)
  }
}
