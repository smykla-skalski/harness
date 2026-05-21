import HarnessMonitorKit
import SwiftUI

struct SettingsSharedRepositoryRow: Identifiable, Equatable {
  let owner: String
  let repository: String
  var dependenciesEnabled: Bool
  var taskBoardEnabled: Bool

  var repositoryPath: String { "\(owner)/\(repository)" }
  var id: String { repositoryPath.lowercased() }
}

struct SettingsSharedRepositoriesDraft: Equatable {
  var rows: [SettingsSharedRepositoryRow] = []
  var legacyOrganizations: [String] = []
  var ownerInput = ""
  var repositoryInput = ""
  private var rowIndexes: [String: Int] = [:]

  init() {}

  init(
    dependenciesPreferences: DashboardDependenciesPreferences,
    taskBoardDraft: TaskBoardGitSettingsDraft
  ) {
    insert(
      repositories: dependenciesPreferences.normalizedRepositories,
      dependenciesEnabled: true,
      taskBoardEnabled: false
    )
    insert(
      repositories: taskBoardDraft.githubInboxRepositoryEntries,
      dependenciesEnabled: false,
      taskBoardEnabled: true
    )
    legacyOrganizations = Self.normalizedOrganizations(
      dependenciesPreferences.normalizedOrganizations)
  }

  var canAddManualRepository: Bool {
    SettingsGitHubRepositoryNormalization.repository(
      owner: ownerInput,
      repo: repositoryInput
    ) != nil
  }

  var dependenciesRepositories: [String] {
    rows.filter(\.dependenciesEnabled).map(\.repositoryPath)
  }

  var taskBoardRepositories: [String] {
    rows.filter(\.taskBoardEnabled).map(\.repositoryPath)
  }

  func index(for rowID: String) -> Int? {
    rowIndexes[rowID]
  }

  mutating func addManualRepository() {
    guard
      let repository = SettingsGitHubRepositoryNormalization.repository(
        owner: ownerInput,
        repo: repositoryInput
      )
    else {
      return
    }
    insert(
      repository: repository,
      dependenciesEnabled: true,
      taskBoardEnabled: true
    )
    ownerInput = ""
    repositoryInput = ""
  }

  mutating func addImportedRepositories(_ repositories: [String]) {
    insert(
      repositories: repositories,
      dependenciesEnabled: true,
      taskBoardEnabled: true
    )
  }

  mutating func setDependenciesEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rowIndexes[rowID] else { return }
    rows[index].dependenciesEnabled = isEnabled
    removeIfDisabled(index: index)
  }

  mutating func setTaskBoardEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rowIndexes[rowID] else { return }
    rows[index].taskBoardEnabled = isEnabled
    removeIfDisabled(index: index)
  }

  mutating func remove(rowID: String) {
    guard let index = rowIndexes[rowID] else { return }
    rows.remove(at: index)
    rebuildRowIndexes()
  }

  mutating func removeLegacyOrganization(_ organization: String) {
    let normalized = organization.lowercased()
    legacyOrganizations.removeAll { $0.lowercased() == normalized }
  }

  private mutating func insert(
    repositories: [String],
    dependenciesEnabled: Bool,
    taskBoardEnabled: Bool
  ) {
    for repository in repositories {
      insert(
        repository: repository,
        dependenciesEnabled: dependenciesEnabled,
        taskBoardEnabled: taskBoardEnabled
      )
    }
  }

  private mutating func insert(
    repository: String,
    dependenciesEnabled: Bool,
    taskBoardEnabled: Bool
  ) {
    guard let normalized = SettingsGitHubRepositoryNormalization.repositoryEntry(repository) else {
      return
    }
    let parts = normalized.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return }
    let candidate = SettingsSharedRepositoryRow(
      owner: parts[0],
      repository: parts[1],
      dependenciesEnabled: dependenciesEnabled,
      taskBoardEnabled: taskBoardEnabled
    )
    if let index = rowIndexes[candidate.id] {
      rows[index].dependenciesEnabled = rows[index].dependenciesEnabled || dependenciesEnabled
      rows[index].taskBoardEnabled = rows[index].taskBoardEnabled || taskBoardEnabled
      return
    }
    rowIndexes[candidate.id] = rows.count
    rows.append(candidate)
  }

  private mutating func removeIfDisabled(index: Int) {
    guard rows.indices.contains(index) else { return }
    guard !rows[index].dependenciesEnabled, !rows[index].taskBoardEnabled else { return }
    rows.remove(at: index)
    rebuildRowIndexes()
  }

  private mutating func rebuildRowIndexes() {
    rowIndexes = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) })
  }

  private static func normalizedOrganizations(_ organizations: [String]) -> [String] {
    var normalized: [String] = []
    var seen: Set<String> = []
    for organization in organizations {
      guard let value = SettingsGitHubRepositoryNormalization.normalized(organization)?.lowercased()
      else {
        continue
      }
      if seen.insert(value).inserted {
        normalized.append(value)
      }
    }
    return normalized
  }
}
