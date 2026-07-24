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
    let associatedProjectDir = await associatedProjectDir(
      for: executionRepository,
      daemonSandboxed: daemonSandboxed
    )
    return TaskBoardWorkingDirectoryResolver.decide(
      hasExistingSession: false,
      executionRepository: executionRepository,
      associatedProjectDir: associatedProjectDir,
      globalProjectDir: globalProjectDir
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
