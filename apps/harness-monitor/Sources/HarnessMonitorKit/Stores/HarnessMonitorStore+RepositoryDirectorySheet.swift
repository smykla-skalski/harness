import Foundation

extension HarnessMonitorStore {
  /// Presents the consolidated sheet for choosing local working directories for
  /// `repositories`.
  public func presentResolveRepositoryDirectories(repositories: [String]) {
    guard !repositories.isEmpty else { return }
    presentedSheet = .resolveRepositoryDirectories(repositories: repositories)
  }

  /// Current working directory for each associated repository, as a displayable
  /// filesystem path resolved from its bookmark record. Repositories whose
  /// bookmark is missing are omitted.
  public func repositoryWorkingDirectoryPaths() async -> [String: String] {
    guard let repositoryDirectoryStore, let bookmarkStore else { return [:] }
    let associations = await repositoryDirectoryStore.allAssociations()
    let pathByBookmarkID = Dictionary(
      await bookmarkStore.all().map { ($0.id, $0.lastResolvedPath) },
      uniquingKeysWith: { first, _ in first }
    )
    return Dictionary(
      associations.compactMap { association in
        pathByBookmarkID[association.bookmarkID].map { (association.repository, $0) }
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// Normalized repositories that carry an association record, whether or not
  /// their bookmark still resolves. Callers use this to offer Remove for a stale
  /// binding whose path `repositoryWorkingDirectoryPaths` omits.
  public func repositoryDirectoryAssociations() async -> Set<String> {
    guard let repositoryDirectoryStore else { return [] }
    return Set(await repositoryDirectoryStore.allAssociations().map(\.repository))
  }

  /// Forgets the working directory associated with `repository`.
  public func removeRepositoryWorkingDirectory(repository: String) async {
    guard let repositoryDirectoryStore else { return }
    do {
      try await repositoryDirectoryStore.removeAssociation(forRepository: repository)
    } catch {
      presentFailureFeedback("Could not remove working directory: \(error.localizedDescription)")
    }
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
