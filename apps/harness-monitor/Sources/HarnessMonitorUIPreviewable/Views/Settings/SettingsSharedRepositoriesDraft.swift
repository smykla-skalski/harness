import HarnessMonitorKit
import SwiftUI

enum SettingsRepositoriesCatalog {
  static let storageKey = "settings.repositories.catalog"

  static func decode(_ value: String) -> [String] {
    SettingsGitHubRepositoryNormalization.repositories(from: value)
  }

  static func encode(_ repositories: [String]) -> String {
    repositories.joined(separator: "\n")
  }
}

struct SettingsSharedRepositoryRow: Identifiable, Equatable {
  let owner: String
  let repository: String
  var reviewsEnabled: Bool
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
    reviewsPreferences: DashboardReviewsPreferences,
    taskBoardDraft: TaskBoardGitSettingsDraft,
    repositoryCatalog: [String] = []
  ) {
    insert(
      repositories: repositoryCatalog,
      reviewsEnabled: false,
      taskBoardEnabled: false
    )
    insert(
      repositories: reviewsPreferences.normalizedRepositories,
      reviewsEnabled: true,
      taskBoardEnabled: false
    )
    insert(
      repositories: taskBoardDraft.githubInboxRepositoryEntries,
      reviewsEnabled: false,
      taskBoardEnabled: true
    )
    legacyOrganizations = Self.normalizedOrganizations(
      reviewsPreferences.normalizedOrganizations)
  }

  var canAddManualRepository: Bool {
    SettingsGitHubRepositoryNormalization.repository(
      owner: ownerInput,
      repo: repositoryInput
    ) != nil
  }

  var reviewsRepositories: [String] {
    rows.filter(\.reviewsEnabled).map(\.repositoryPath)
  }

  var taskBoardRepositories: [String] {
    rows.filter(\.taskBoardEnabled).map(\.repositoryPath)
  }

  var repositoryCatalog: [String] {
    rows.map(\.repositoryPath)
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
      reviewsEnabled: true,
      taskBoardEnabled: true
    )
    ownerInput = ""
    repositoryInput = ""
  }

  mutating func addImportedRepositories(_ repositories: [String]) {
    insert(
      repositories: repositories,
      reviewsEnabled: true,
      taskBoardEnabled: true
    )
  }

  mutating func setReviewsEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rowIndexes[rowID] else { return }
    rows[index].reviewsEnabled = isEnabled
  }

  mutating func setTaskBoardEnabled(_ isEnabled: Bool, for rowID: String) {
    guard let index = rowIndexes[rowID] else { return }
    rows[index].taskBoardEnabled = isEnabled
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
    reviewsEnabled: Bool,
    taskBoardEnabled: Bool
  ) {
    for repository in repositories {
      insert(
        repository: repository,
        reviewsEnabled: reviewsEnabled,
        taskBoardEnabled: taskBoardEnabled
      )
    }
  }

  private mutating func insert(
    repository: String,
    reviewsEnabled: Bool,
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
      reviewsEnabled: reviewsEnabled,
      taskBoardEnabled: taskBoardEnabled
    )
    if let index = rowIndexes[candidate.id] {
      rows[index].reviewsEnabled = rows[index].reviewsEnabled || reviewsEnabled
      rows[index].taskBoardEnabled = rows[index].taskBoardEnabled || taskBoardEnabled
      return
    }
    rowIndexes[candidate.id] = rows.count
    rows.append(candidate)
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
