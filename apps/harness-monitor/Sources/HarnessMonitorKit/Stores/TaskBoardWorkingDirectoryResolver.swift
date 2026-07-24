import Foundation

/// Decides where a task-board dispatch should run and which imported
/// repositories still need a local working directory before they can.
///
/// Pure logic, shared by the step-mode deliver path and the consolidated
/// working-directory sheet. A create-session dispatch needs a directory; an
/// item that reuses an existing session does not. Imported items carry an
/// `execution_repository` slug but no directory, so their directory comes from
/// the per-repository association the user set once (see
/// `RepositoryDirectoryStore`). Items with no repository keep using the global
/// project directory as before.
public enum TaskBoardWorkingDirectoryResolver {
  public struct ItemNeed: Sendable, Equatable {
    public let hasExistingSession: Bool
    public let executionRepository: String?

    public init(hasExistingSession: Bool, executionRepository: String?) {
      self.hasExistingSession = hasExistingSession
      self.executionRepository = executionRepository
    }
  }

  public enum Decision: Sendable, Equatable {
    /// Proceed with this project directory (`nil` when the daemon needs none:
    /// an existing session, or the legacy global-directory path).
    case dispatch(projectDir: String?)
    /// The item's repository has no working directory yet; the caller must
    /// resolve `repository` (via the sheet) before dispatching.
    case needsWorkingDirectory(repository: String)
  }

  /// Distinct, normalized repositories among `items` that still need a local
  /// working directory: a create-session item with an `execution_repository`
  /// that has no association yet. Deduplicated by slug so several items from the
  /// same repository collapse to one entry, and sorted for a stable sheet order.
  public static func unresolvedRepositories(
    items: [ItemNeed],
    isAssociated: (String) -> Bool
  ) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for item in items {
      guard !item.hasExistingSession else { continue }
      let repository = normalizedRepository(item.executionRepository)
      guard let repository, !isAssociated(repository) else { continue }
      if seen.insert(repository).inserted {
        result.append(repository)
      }
    }
    return result.sorted()
  }

  /// Decide the project directory for one dispatch. `associatedProjectDir` is
  /// the value the caller resolved for the item's repository (a bookmark id on a
  /// sandboxed daemon, or a filesystem path otherwise), or `nil` when the
  /// repository has no association.
  public static func decide(
    hasExistingSession: Bool,
    executionRepository: String?,
    associatedProjectDir: String?,
    globalProjectDir: String?
  ) -> Decision {
    if hasExistingSession {
      return .dispatch(projectDir: nil)
    }
    guard let repository = normalizedRepository(executionRepository) else {
      return .dispatch(projectDir: globalProjectDir)
    }
    guard let associatedProjectDir else {
      return .needsWorkingDirectory(repository: repository)
    }
    return .dispatch(projectDir: associatedProjectDir)
  }

  private static func normalizedRepository(_ repository: String?) -> String? {
    guard let repository else { return nil }
    let normalized = RepositoryDirectoryStore.normalizedRepository(repository)
    return normalized.isEmpty ? nil : normalized
  }
}
