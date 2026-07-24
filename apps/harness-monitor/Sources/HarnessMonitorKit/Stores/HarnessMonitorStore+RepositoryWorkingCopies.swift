import Foundation

extension HarnessMonitorStore {
  /// One-shot fetch of the daemon-owned working copies for the Settings panel
  /// and the resolve sheet. Returns an empty array when the client is not wired
  /// or the request fails, so the UI renders the empty state without extra
  /// error plumbing.
  public func listRepositoryWorkingCopies() async -> [WorkingCopyListEntry] {
    guard let client else { return [] }
    do {
      return try await client.taskBoardWorkingCopies()
    } catch {
      return []
    }
  }

  /// Obtain (clone if missing) a working copy for `repository`. Returns the
  /// resulting entry, or `nil` when the client is unavailable or the clone
  /// failed (no token, network, or the daemon lacks the endpoint).
  @discardableResult
  public func obtainRepositoryWorkingCopy(
    repository: String
  ) async -> WorkingCopyListEntry? {
    guard let client else { return nil }
    do {
      return try await client.obtainTaskBoardWorkingCopy(
        repository: repository,
        allowClone: true
      )
    } catch {
      return nil
    }
  }

  /// Delete a working copy by its `repoKeySegment`, reclaiming its disk. Returns
  /// `true` on daemon-confirmed deletion.
  @discardableResult
  public func deleteRepositoryWorkingCopy(repoKeySegment: String) async -> Bool {
    guard let client else { return false }
    do {
      try await client.deleteTaskBoardWorkingCopy(repoKeySegment: repoKeySegment)
      return true
    } catch {
      return false
    }
  }
}
