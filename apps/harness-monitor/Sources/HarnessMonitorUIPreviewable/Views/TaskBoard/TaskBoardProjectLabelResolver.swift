import Foundation
import HarnessMonitorKit
import SwiftUI

struct TaskBoardProjectLabelResolver: Equatable, Sendable {
  private let ambiguousRepositoryNames: Set<String>
  private let projectsByID: [String: RegisteredProject]

  init(projectIDs: [String]) {
    self.init(projects: [], projectIDs: projectIDs)
  }

  /// `projects` is the registered catalog an item's `sourceProjectId` points
  /// into. `projectIDs` are the repository identities read off the items
  /// themselves, which still matter for an item whose project has not been
  /// registered yet and for deciding which repository names are ambiguous.
  init(projects: [TaskBoardProjectSummary], projectIDs: [String]) {
    var projectIDsByRepositoryName: [String: Set<String>] = [:]
    for slug in projectIDs + projects.map(\.slug) {
      guard let components = Self.components(of: slug) else {
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
    projectsByID = Dictionary(
      projects.map {
        (
          $0.projectId,
          RegisteredProject(slug: $0.slug, displayName: $0.displayName, color: $0.color)
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  /// The color of the project an item belongs to, or nil when it belongs to
  /// none. Only a registered project has one: an item naming a repository the
  /// registry has not seen yet gets no mark rather than an invented color.
  func color(for item: TaskBoardItem) -> TaskBoardProjectColor? {
    item.sourceProjectId.flatMap { projectsByID[$0]?.color }
  }

  /// The project an item belongs to, or nil when it belongs to none. Prefers
  /// the registered project so a renamed project reads by its current name,
  /// and falls back to the repository identity carried on the item itself.
  func label(for item: TaskBoardItem, alwaysShowFullName: Bool = false) -> String? {
    if let projectID = item.sourceProjectId,
      let registered = projectsByID[projectID]
    {
      // A display name is what a person chose to call the project, so it is
      // shown exactly as typed rather than run through slug shortening.
      if let displayName = registered.displayName,
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return displayName
      }
      return label(for: registered.slug, alwaysShowFullName: alwaysShowFullName)
    }
    guard let repositoryID = item.taskBoardRepositoryIdentity else {
      return nil
    }
    return label(for: repositoryID, alwaysShowFullName: alwaysShowFullName)
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

private struct RegisteredProject: Equatable, Sendable {
  let slug: String
  let displayName: String?
  let color: TaskBoardProjectColor
}

private struct ProjectComponents {
  let repositoryName: String
  let repositoryNameKey: String
  let projectIDKey: String
}

extension EnvironmentValues {
  @Entry var taskBoardProjectLabelResolver = TaskBoardProjectLabelResolver(projectIDs: [])
}
