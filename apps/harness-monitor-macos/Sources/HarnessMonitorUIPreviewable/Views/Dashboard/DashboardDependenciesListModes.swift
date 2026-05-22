import Foundation
import HarnessMonitorKit

struct DashboardDependenciesRepositoryOrdering {
  let configuredRepositories: [String]
  let configuredOrganizations: [String]

  func compare(_ lhs: String, _ rhs: String) -> Bool {
    sortKey(for: lhs) < sortKey(for: rhs)
  }

  func sorted(_ repositories: [String]) -> [String] {
    repositories.sorted(by: compare)
  }

  private func sortKey(for repository: String) -> DashboardDependenciesRepositorySortKey {
    if let index = configuredRepositories.firstIndex(of: repository) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 0,
        configuredIndex: index,
        organization: repositoryOwner(for: repository),
        repository: repository
      )
    }
    let organization = repositoryOwner(for: repository)
    if let index = configuredOrganizations.firstIndex(of: organization) {
      return DashboardDependenciesRepositorySortKey(
        bucket: 1,
        configuredIndex: index,
        organization: organization,
        repository: repository
      )
    }
    return DashboardDependenciesRepositorySortKey(
      bucket: 2,
      configuredIndex: Int.max,
      organization: organization,
      repository: repository
    )
  }

  private func repositoryOwner(for repository: String) -> String {
    repository.split(separator: "/", maxSplits: 1).first.map(String.init) ?? repository
  }
}

struct DashboardDependenciesCollapsedRepositories: Codable, Equatable {
  var repositories: [String] = []

  var encodedString: String {
    DashboardDependenciesStorageCodec.encodeToString(self)
  }

  func contains(_ repository: String) -> Bool {
    repositories.contains(repository)
  }

  mutating func toggle(_ repository: String) {
    if let index = repositories.firstIndex(of: repository) {
      repositories.remove(at: index)
    } else {
      repositories.append(repository)
      repositories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    }
  }

  static func decode(from string: String) -> Self {
    DashboardDependenciesStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}

private struct DashboardDependenciesRepositorySortKey: Comparable {
  let bucket: Int
  let configuredIndex: Int
  let organization: String
  let repository: String

  static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.bucket != rhs.bucket {
      return lhs.bucket < rhs.bucket
    }
    if lhs.configuredIndex != rhs.configuredIndex {
      return lhs.configuredIndex < rhs.configuredIndex
    }
    if lhs.organization != rhs.organization {
      return lhs.organization.localizedStandardCompare(rhs.organization) == .orderedAscending
    }
    return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
  }
}

enum DashboardDependenciesFilterMode: String, CaseIterable, Identifiable {
  case all
  case ready
  case review
  case waiting
  case blocked

  static let pickerCases: [Self] = [.all, .ready, .review, .waiting, .blocked]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .ready: "Ready"
    case .review: "Review"
    case .waiting: "Waiting"
    case .blocked: "Blocked"
    }
  }

  func matches(_ item: DependencyUpdateItem) -> Bool {
    switch self {
    case .all: true
    case .ready: item.isAutoMergeable
    case .review: item.reviewStatus == .reviewRequired
    case .waiting: item.checkStatus == .pending
    case .blocked: item.requiresAttention
    }
  }
}

enum DashboardDependenciesSortMode: String, CaseIterable, Identifiable {
  case status
  case age
  case repository

  static let pickerCases: [Self] = [.status, .age, .repository]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .status: "Status"
    case .age: "Age"
    case .repository: "Repository"
    }
  }

  var comparator: (DependencyUpdateItem, DependencyUpdateItem) -> Bool {
    switch self {
    case .status:
      { lhs, rhs in
        if lhs.statusWeight == rhs.statusWeight {
          return lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending
        }
        return lhs.statusWeight < rhs.statusWeight
      }
    case .age:
      { lhs, rhs in lhs.createdAt > rhs.createdAt }
    case .repository:
      { lhs, rhs in lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending }
    }
  }
}

enum DashboardDependenciesGroupMode: String, CaseIterable, Identifiable {
  case repository
  case flat

  static let pickerCases: [Self] = [.repository, .flat]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository: "By Repo"
    case .flat: "Flat"
    }
  }
}
