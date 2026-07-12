import Foundation
import SwiftUI

struct TaskBoardProjectLabelResolver: Equatable, Sendable {
  private let ambiguousRepositoryNames: Set<String>

  init(projectIDs: [String]) {
    var projectIDsByRepositoryName: [String: Set<String>] = [:]
    for projectID in projectIDs {
      guard let components = Self.components(of: projectID) else {
        continue
      }
      projectIDsByRepositoryName[components.repositoryNameKey, default: []]
        .insert(components.projectIDKey)
    }
    ambiguousRepositoryNames = Set(
      projectIDsByRepositoryName.compactMap { repositoryName, projectIDs in
        projectIDs.count > 1 ? repositoryName : nil
      }
    )
  }

  func label(for projectID: String, alwaysShowFullName: Bool = false) -> String {
    guard
      !alwaysShowFullName,
      let components = Self.components(of: projectID),
      !ambiguousRepositoryNames.contains(components.repositoryNameKey)
    else {
      return projectID
    }
    return components.repositoryName
  }

  private static func components(of projectID: String) -> ProjectComponents? {
    guard projectID == projectID.trimmingCharacters(in: .whitespacesAndNewlines) else {
      return nil
    }
    let components = projectID.split(separator: "/", omittingEmptySubsequences: false)
    guard
      components.count == 2,
      let owner = components.first,
      let repositoryName = components.last,
      !owner.isEmpty,
      !repositoryName.isEmpty
    else {
      return nil
    }
    return ProjectComponents(
      repositoryName: String(repositoryName),
      repositoryNameKey: repositoryName.lowercased(),
      projectIDKey: projectID.lowercased()
    )
  }
}

private struct ProjectComponents {
  let repositoryName: String
  let repositoryNameKey: String
  let projectIDKey: String
}

extension EnvironmentValues {
  @Entry var taskBoardProjectLabelResolver = TaskBoardProjectLabelResolver(projectIDs: [])
}
