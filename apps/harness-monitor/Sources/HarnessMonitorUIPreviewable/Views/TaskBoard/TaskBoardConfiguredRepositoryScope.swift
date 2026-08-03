import Foundation
import HarnessMonitorKit

struct TaskBoardConfiguredRepositoryScope: Equatable, Sendable {
  private let repositories: Set<String>?
  private let githubProjectRepositories: [String: String]
  private let localProjectIDs: Set<String>

  init(
    repositories: [String]?,
    projects: [TaskBoardProjectSummary]
  ) {
    self.repositories = repositories.map { repositories in
      Set(repositories.compactMap(Self.normalizedRepository))
    }
    githubProjectRepositories = Dictionary(
      projects.compactMap { project in
        guard
          project.source == .gitHub,
          let repository = Self.normalizedRepository(project.slug)
        else {
          return nil
        }
        return (project.projectId, repository)
      },
      uniquingKeysWith: { first, _ in first }
    )
    localProjectIDs = Set(
      projects.lazy.filter { $0.source != .gitHub }.map(\.projectId)
    )
  }

  func filter(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    guard let repositories else { return items }
    return items.filter { allows($0, repositories: repositories) }
  }

  private func allows(
    _ item: TaskBoardItem,
    repositories: Set<String>
  ) -> Bool {
    if let executionRepository = item.executionRepository {
      return Self.normalizedRepository(executionRepository).map(repositories.contains) ?? false
    }
    if let sourceProjectID = item.sourceProjectId {
      if let repository = githubProjectRepositories[sourceProjectID] {
        return repositories.contains(repository)
      }
      if localProjectIDs.contains(sourceProjectID) {
        return true
      }
    }
    if let repositoryIdentity = item.taskBoardRepositoryIdentity {
      return Self.normalizedRepository(repositoryIdentity).map(repositories.contains) ?? false
    }
    return true
  }

  private static func normalizedRepository(_ repository: String) -> String? {
    let normalized = RepositoryDirectoryStore.normalizedRepository(repository)
    return normalized.isEmpty ? nil : normalized
  }
}
