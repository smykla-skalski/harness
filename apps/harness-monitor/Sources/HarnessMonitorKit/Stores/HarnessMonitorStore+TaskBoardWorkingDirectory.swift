import Foundation

extension HarnessMonitorStore {
  /// Decide the project directory for delivering a task-board item, resolving an
  /// imported repository to the working directory the user associated with it.
  ///
  /// A sandboxed daemon receives the bookmark id (it resolves the security scope
  /// itself); a non-sandboxed daemon receives the resolved filesystem path. When
  /// an imported repository has no association, or its bookmark no longer
  /// resolves, the item reports `needsWorkingDirectory` so the caller can prompt.
  public func taskBoardDeliveryDirectory(
    hasExistingSession: Bool,
    executionRepository: String?,
    globalProjectDir: String?,
    daemonSandboxed: Bool
  ) async -> TaskBoardWorkingDirectoryResolver.Decision {
    if hasExistingSession {
      return .dispatch(projectDir: nil)
    }
    // A user-picked folder (a bookmark) wins; otherwise fall back to a
    // daemon-obtained working copy. Resolving the copy also bumps its
    // last_used_at so an actively-delivered checkout is never garbage-collected.
    var associatedProjectDir = await associatedProjectDir(
      for: executionRepository,
      daemonSandboxed: daemonSandboxed
    )
    if associatedProjectDir == nil {
      associatedProjectDir = await managedWorkingCopyProjectDir(for: executionRepository)
    }
    return TaskBoardWorkingDirectoryResolver.decide(
      hasExistingSession: false,
      executionRepository: executionRepository,
      associatedProjectDir: associatedProjectDir,
      globalProjectDir: globalProjectDir
    )
  }

  /// Distinct repositories among `items` that still need a local working
  /// directory, deduplicated by slug so the sheet shows one row per repository.
  public func unresolvedTaskBoardRepositories(
    items: [TaskBoardWorkingDirectoryResolver.ItemNeed],
    daemonSandboxed: Bool
  ) async -> [String] {
    // "Resolved" has to mean the same thing the dispatch decision uses: an
    // association whose working directory actually resolves for this daemon. A
    // record whose bookmark no longer resolves (folder moved or deleted) must
    // re-prompt, not get filtered out as already associated - otherwise Deliver
    // would silently do nothing.
    let managedPresent = await managedWorkingCopySlugs()
    var resolved: Set<String> = []
    for repository in distinctCreateRepositories(items) {
      let hasBookmark =
        await associatedProjectDir(for: repository, daemonSandboxed: daemonSandboxed) != nil
      if hasBookmark || managedPresent.contains(repository) {
        resolved.insert(repository)
      }
    }
    return TaskBoardWorkingDirectoryResolver.unresolvedRepositories(items: items) {
      resolved.contains($0)
    }
  }

  /// Resolve a daemon-obtained working copy for `executionRepository` without
  /// cloning: returns the checkout path when a copy already exists (bumping its
  /// last_used_at), or `nil` so delivery falls through to prompting the user.
  private func managedWorkingCopyProjectDir(for executionRepository: String?) async -> String? {
    guard let executionRepository, let client else { return nil }
    let normalized = RepositoryDirectoryStore.normalizedRepository(executionRepository)
    guard !normalized.isEmpty else { return nil }
    return try? await client
      .obtainTaskBoardWorkingCopy(repository: normalized, allowClone: false)?
      .path
  }

  /// Normalized slugs of repositories that already have a daemon-owned working
  /// copy, used as the batch "resolved" signal for the consolidated sheet.
  private func managedWorkingCopySlugs() async -> Set<String> {
    let entries = await listRepositoryWorkingCopies()
    return Set(entries.map { RepositoryDirectoryStore.normalizedRepository($0.repoFullName) })
  }

  private func distinctCreateRepositories(
    _ items: [TaskBoardWorkingDirectoryResolver.ItemNeed]
  ) -> Set<String> {
    Set(
      items
        .filter { !$0.hasExistingSession }
        .compactMap { item in
          guard let raw = item.executionRepository else { return nil }
          let normalized = RepositoryDirectoryStore.normalizedRepository(raw)
          return normalized.isEmpty ? nil : normalized
        }
    )
  }

  private func associatedProjectDir(
    for executionRepository: String?,
    daemonSandboxed: Bool
  ) async -> String? {
    guard
      let executionRepository,
      let repositoryDirectoryStore,
      let bookmarkID = await repositoryDirectoryStore.bookmarkID(
        forRepository: executionRepository
      )
    else { return nil }
    if daemonSandboxed {
      return bookmarkID
    }
    guard let bookmarkStore else { return nil }
    let scope = try? await bookmarkStore.resolve(id: bookmarkID)
    return scope?.url.path
  }
}
