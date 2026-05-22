import Foundation

extension HarnessMonitorStore {
  /// One-shot fetch of the local-clone listing for the Settings panel.
  /// Returns an empty array when the daemon client is not yet wired or
  /// the request fails so the UI can render the empty-state without
  /// extra error plumbing.
  public func listDependencyUpdateLocalClones() async -> [DependencyUpdateLocalCloneEntry] {
    guard let client else { return [] }
    do {
      return try await client.listDependencyUpdateLocalClones()
    } catch {
      return []
    }
  }

  /// Delete a single local clone identified by its `repoKeySegment`
  /// (`<sha-prefix>__<safe-owner>__<safe-name>`). Returns `true` on
  /// daemon-confirmed deletion, `false` when the daemon refuses or the
  /// client is unavailable.
  @discardableResult
  public func deleteDependencyUpdateLocalClone(
    repoKeySegment: String
  ) async -> Bool {
    guard let client else { return false }
    do {
      try await client.deleteDependencyUpdateLocalClone(repoKeySegment: repoKeySegment)
      return true
    } catch {
      return false
    }
  }
}
