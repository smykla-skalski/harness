import Foundation

extension HarnessMonitorStore {
  /// Presents the consolidated sheet for choosing local working directories for
  /// `repositories`.
  public func presentResolveRepositoryDirectories(repositories: [String]) {
    guard !repositories.isEmpty else { return }
    presentedSheet = .resolveRepositoryDirectories(repositories: repositories)
  }

  /// Associates the folder the user picked with `repository`, storing the
  /// security-scoped bookmark so later deliveries reuse it without prompting.
  @discardableResult
  public func resolveRepositoryWorkingDirectory(
    repository: String,
    from result: Result<[URL], any Error>
  ) async -> Bool {
    guard let record = await handleImportedFolder(result) else { return false }
    guard let repositoryDirectoryStore else {
      presentFailureFeedback("Repository directory store unavailable: app group container missing")
      return false
    }
    do {
      try await repositoryDirectoryStore.associate(repository: repository, bookmarkID: record.id)
      return true
    } catch {
      presentFailureFeedback("Could not save working directory: \(error.localizedDescription)")
      return false
    }
  }
}
