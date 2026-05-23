import Foundation
import HarnessMonitorKit

struct DashboardReviewsRepositoryOrdering {
  let configuredRepositories: [String]
  let configuredOrganizations: [String]

  func compare(_ lhs: String, _ rhs: String) -> Bool {
    sortKey(for: lhs) < sortKey(for: rhs)
  }

  func sorted(_ repositories: [String]) -> [String] {
    repositories.sorted(by: compare)
  }

  private func sortKey(for repository: String) -> DashboardReviewsRepositorySortKey {
    if let index = configuredRepositories.firstIndex(of: repository) {
      return DashboardReviewsRepositorySortKey(
        bucket: 0,
        configuredIndex: index,
        organization: repositoryOwner(for: repository),
        repository: repository
      )
    }
    let organization = repositoryOwner(for: repository)
    if let index = configuredOrganizations.firstIndex(of: organization) {
      return DashboardReviewsRepositorySortKey(
        bucket: 1,
        configuredIndex: index,
        organization: organization,
        repository: repository
      )
    }
    return DashboardReviewsRepositorySortKey(
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

struct DashboardReviewsCollapsedRepositories: Codable, Equatable {
  var repositories: [String] = []

  var encodedString: String {
    DashboardReviewsStorageCodec.encodeToString(self)
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
    DashboardReviewsStorageCodec.decode(Self.self, from: string) ?? Self()
  }
}

private struct DashboardReviewsRepositorySortKey: Comparable {
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

enum DashboardReviewsFilterMode: String, CaseIterable, Identifiable {
  case all
  case ready
  case review
  case waiting

  static let pickerCases: [Self] = [.all, .ready, .review, .waiting]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All open"
    case .ready: "Ready to merge"
    case .review: "Needs review"
    case .waiting: "Waiting on checks"
    }
  }

  func matches(_ item: ReviewItem) -> Bool {
    switch self {
    case .all: true
    case .ready: item.isAutoMergeable
    case .review: item.reviewStatus == .reviewRequired
    case .waiting: item.checkStatus == .pending
    }
  }
}

enum DashboardReviewsSortMode: String, CaseIterable, Identifiable {
  case status
  case updated
  case created
  case repository

  static let pickerCases: [Self] = [.status, .updated, .created, .repository]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .status: "Status"
    case .updated: "Updated"
    case .created: "Created"
    case .repository: "Repository"
    }
  }

  var comparator: (ReviewItem, ReviewItem) -> Bool {
    switch self {
    case .status:
      { lhs, rhs in lhs.statusOrderKey < rhs.statusOrderKey }
    case .updated:
      { lhs, rhs in lhs.updatedAt > rhs.updatedAt }
    case .created:
      { lhs, rhs in lhs.createdAt > rhs.createdAt }
    case .repository:
      { lhs, rhs in lhs.repository.localizedStandardCompare(rhs.repository) == .orderedAscending }
    }
  }
}

enum DashboardReviewsGroupMode: String, CaseIterable, Identifiable {
  case repository
  case status
  case author
  case flat

  static let pickerCases: [Self] = [.repository, .status, .author, .flat]

  var id: String { rawValue }

  var title: String {
    switch self {
    case .repository: "By Repository"
    case .status: "By Status"
    case .author: "By Author"
    case .flat: "Flat"
    }
  }
}

enum DashboardReviewsCategoryMode: String, CaseIterable, Identifiable {
  case all
  case dependencies

  static let pickerCases: [Self] = [.all, .dependencies]
  static var defaultMode: Self { .all }

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: "All"
    case .dependencies: "Dependencies"
    }
  }

  func matches(_ item: ReviewItem) -> Bool {
    switch self {
    case .all: true
    case .dependencies: ReviewBot.detect(authorLogin: item.authorLogin) != nil
    }
  }
}
