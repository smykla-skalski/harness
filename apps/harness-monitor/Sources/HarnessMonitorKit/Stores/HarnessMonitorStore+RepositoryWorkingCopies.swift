import Foundation

extension HarnessMonitorStore {
  /// One-shot fetch of the daemon-owned working copies for the Settings panel
  /// and the resolve sheet. Returns an empty array when the client is not wired
  /// or the request fails, so the UI renders the empty state without extra
  /// error plumbing.
  public func listRepositoryWorkingCopies() async -> [WorkingCopyListEntry] {
    guard let access = availableTaskBoardClientAccess else { return [] }
    do {
      let entries = try await access.client.taskBoardWorkingCopies()
      try requireCurrentTaskBoardClientAccess(access)
      return entries
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
    guard let access = availableTaskBoardClientAccess else { return nil }
    do {
      let entry = try await access.client.obtainTaskBoardWorkingCopy(
        repository: repository,
        allowClone: true
      )
      try requireCurrentTaskBoardClientAccess(access)
      return entry
    } catch {
      return nil
    }
  }

  /// Delete a working copy by its `repoKeySegment`, reclaiming its disk. Returns
  /// `true` on daemon-confirmed deletion.
  @discardableResult
  public func deleteRepositoryWorkingCopy(repoKeySegment: String) async -> Bool {
    guard let access = availableTaskBoardClientAccess else { return false }
    do {
      try await access.client.deleteTaskBoardWorkingCopy(repoKeySegment: repoKeySegment)
      try requireCurrentTaskBoardClientAccess(access)
      return true
    } catch {
      return false
    }
  }
}
