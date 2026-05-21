import Foundation
import HarnessMonitorKit

struct DashboardDependenciesPreferences: Codable, Equatable {
  static let storageKey = "dashboard.dependencies.preferences"
  static let minimumPerRepositoryIntervalSeconds: UInt64 = 30
  static let maximumPerRepositoryIntervalSeconds: UInt64 = 3_600
  static let minimumConcurrentRepositoryFetches: Int = 1
  static let maximumConcurrentRepositoryFetches: Int = 8
  static let minimumFrequentLabelsCount: Int = 1
  static let maximumFrequentLabelsCount: Int = 10
  static let defaultFrequentLabelsCount: Int = 5

  var authorsText = "renovate[bot]"
  var organizationsText = ""
  var repositoriesText = ""
  var excludeRepositoriesText = ""
  var mergeMethodRaw = TaskBoardGitHubMergeMethod.squash.rawValue
  var refreshIntervalSeconds: UInt64 = 300
  var cacheMaxAgeSeconds: UInt64 = 600
  var showLabelDescriptions = false
  var frequentLabelsCount: Int = defaultFrequentLabelsCount
  var perRepositoryIntervalSeconds: UInt64 = 300
  var maxConcurrentRepositoryFetches: Int = 2
  var expandOrganizations: Bool = true

  enum CodingKeys: String, CodingKey {
    case authorsText
    case organizationsText
    case repositoriesText
    case excludeRepositoriesText
    case mergeMethodRaw
    case refreshIntervalSeconds
    case cacheMaxAgeSeconds
    case showLabelDescriptions
    case frequentLabelsCount
    case perRepositoryIntervalSeconds
    case maxConcurrentRepositoryFetches
    case expandOrganizations
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self()
    authorsText =
      try container.decodeIfPresent(String.self, forKey: .authorsText) ?? defaults.authorsText
    organizationsText =
      try container.decodeIfPresent(String.self, forKey: .organizationsText)
      ?? defaults.organizationsText
    repositoriesText =
      try container.decodeIfPresent(String.self, forKey: .repositoriesText)
      ?? defaults.repositoriesText
    excludeRepositoriesText =
      try container.decodeIfPresent(String.self, forKey: .excludeRepositoriesText)
      ?? defaults.excludeRepositoriesText
    mergeMethodRaw =
      try container.decodeIfPresent(String.self, forKey: .mergeMethodRaw)
      ?? defaults.mergeMethodRaw
    refreshIntervalSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .refreshIntervalSeconds)
      ?? defaults.refreshIntervalSeconds
    cacheMaxAgeSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .cacheMaxAgeSeconds)
      ?? defaults.cacheMaxAgeSeconds
    showLabelDescriptions =
      try container.decodeIfPresent(Bool.self, forKey: .showLabelDescriptions)
      ?? defaults.showLabelDescriptions
    frequentLabelsCount =
      try container.decodeIfPresent(Int.self, forKey: .frequentLabelsCount)
      ?? defaults.frequentLabelsCount
    perRepositoryIntervalSeconds =
      try container.decodeIfPresent(UInt64.self, forKey: .perRepositoryIntervalSeconds)
      ?? refreshIntervalSeconds
    maxConcurrentRepositoryFetches =
      try container.decodeIfPresent(Int.self, forKey: .maxConcurrentRepositoryFetches)
      ?? defaults.maxConcurrentRepositoryFetches
    expandOrganizations =
      try container.decodeIfPresent(Bool.self, forKey: .expandOrganizations)
      ?? defaults.expandOrganizations
  }

  var mergeMethod: TaskBoardGitHubMergeMethod {
    TaskBoardGitHubMergeMethod(rawValue: mergeMethodRaw)
  }

  var normalizedOrganizations: [String] {
    Self.normalizedEntries(organizationsText)
  }

  var normalizedRepositories: [String] {
    Self.normalizedEntries(repositoriesText)
  }

  var normalizedExcludeRepositories: [String] {
    Self.normalizedEntries(excludeRepositoriesText)
  }

  var normalizedAuthors: [String] {
    Self.normalizedEntries(authorsText)
  }

  var refreshIntervalDescription: String {
    if refreshIntervalSeconds.isMultiple(of: 60) {
      let minutes = refreshIntervalSeconds / 60
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }
    return "\(refreshIntervalSeconds)s"
  }

  var perRepositoryIntervalDescription: String {
    if perRepositoryIntervalSeconds.isMultiple(of: 60) {
      let minutes = perRepositoryIntervalSeconds / 60
      return minutes == 1 ? "1 min" : "\(minutes) min"
    }
    return "\(perRepositoryIntervalSeconds)s"
  }

  var encodedString: String {
    let encoder = JSONEncoder()
    guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
  }

  func normalized() -> Self {
    var copy = self
    copy.authorsText = Self.normalizedText(authorsText)
    copy.organizationsText = Self.normalizedText(organizationsText)
    copy.repositoriesText = Self.normalizedText(repositoriesText)
    copy.excludeRepositoriesText = Self.normalizedText(excludeRepositoriesText)
    copy.refreshIntervalSeconds = max(
      refreshIntervalSeconds, Self.minimumPerRepositoryIntervalSeconds)
    copy.cacheMaxAgeSeconds = max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    copy.perRepositoryIntervalSeconds = min(
      max(perRepositoryIntervalSeconds, Self.minimumPerRepositoryIntervalSeconds),
      Self.maximumPerRepositoryIntervalSeconds
    )
    copy.maxConcurrentRepositoryFetches = min(
      max(maxConcurrentRepositoryFetches, Self.minimumConcurrentRepositoryFetches),
      Self.maximumConcurrentRepositoryFetches
    )
    copy.frequentLabelsCount = min(
      max(frequentLabelsCount, Self.minimumFrequentLabelsCount),
      Self.maximumFrequentLabelsCount
    )
    return copy
  }

  static func decode(from string: String) -> Self {
    guard
      let data = string.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else {
      return Self()
    }
    return decoded
  }

  func queryRequest(forceRefresh: Bool) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest(
      authors: normalizedAuthors,
      organizations: normalizedOrganizations,
      repositories: normalizedRepositories,
      excludeRepositories: normalizedExcludeRepositories,
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    )
  }

  func perRepositoryQueryRequest(
    for repository: String,
    forceRefresh: Bool
  ) -> DependencyUpdatesQueryRequest {
    DependencyUpdatesQueryRequest(
      authors: normalizedAuthors,
      organizations: [],
      repositories: [repository],
      excludeRepositories: normalizedExcludeRepositories,
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, Self.minimumPerRepositoryIntervalSeconds)
    )
  }

  private static func normalizedText(_ text: String) -> String {
    normalizedEntries(text).joined(separator: ", ")
  }

  private static func normalizedEntries(_ text: String) -> [String] {
    text
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .removingDuplicates()
  }
}
