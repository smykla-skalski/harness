import Foundation

public struct MobileRemoteDaemonReviewsQuery: Codable, Equatable, Sendable {
  public var authors: [String]
  public var organizations: [String]
  public var repositories: [String]
  public var excludeRepositories: [String]
  public var forceRefresh: Bool
  public var cacheMaxAgeSeconds: UInt64
  public var backportDetectionEnabled: Bool
  public var backportPatterns: [String]

  public init(
    authors: [String] = [],
    organizations: [String] = [],
    repositories: [String] = [],
    excludeRepositories: [String] = [],
    forceRefresh: Bool = false,
    cacheMaxAgeSeconds: UInt64 = 600,
    backportDetectionEnabled: Bool = true,
    backportPatterns: [String] = []
  ) {
    self.authors = authors
    self.organizations = organizations
    self.repositories = repositories
    self.excludeRepositories = excludeRepositories
    self.forceRefresh = forceRefresh
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
    self.backportDetectionEnabled = backportDetectionEnabled
    self.backportPatterns = backportPatterns
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      authors: try container.decodeIfPresent([String].self, forKey: .authors) ?? [],
      organizations: try container.decodeIfPresent([String].self, forKey: .organizations) ?? [],
      repositories: try container.decodeIfPresent([String].self, forKey: .repositories) ?? [],
      excludeRepositories: try container.decodeIfPresent(
        [String].self,
        forKey: .excludeRepositories
      ) ?? [],
      forceRefresh: try container.decodeIfPresent(Bool.self, forKey: .forceRefresh) ?? false,
      cacheMaxAgeSeconds: try container.decodeIfPresent(
        UInt64.self,
        forKey: .cacheMaxAgeSeconds
      ) ?? 600,
      backportDetectionEnabled: try container.decodeIfPresent(
        Bool.self,
        forKey: .backportDetectionEnabled
      ) ?? true,
      backportPatterns: try container.decodeIfPresent(
        [String].self,
        forKey: .backportPatterns
      ) ?? []
    )
  }

  var isValidProfile: Bool {
    let scopes = organizations + repositories
    return cacheMaxAgeSeconds > 0
      && scopes.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  enum CodingKeys: String, CodingKey {
    case authors
    case organizations
    case repositories
    case excludeRepositories = "exclude_repositories"
    case forceRefresh = "force_refresh"
    case cacheMaxAgeSeconds = "cache_max_age_seconds"
    case backportDetectionEnabled = "backport_detection_enabled"
    case backportPatterns = "backport_patterns"
  }
}
