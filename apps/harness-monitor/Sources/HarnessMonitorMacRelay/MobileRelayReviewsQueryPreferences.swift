import Foundation
import HarnessMonitorKit

public struct MobileRelayReviewsQueryPreferences: Equatable, Sendable {
  public static let storageKey = "dashboard.reviews.preferences"
  public static let minimumCacheMaxAgeSeconds: UInt64 = 30

  public var authorsText: String
  public var organizationsText: String
  public var repositoriesText: String
  public var excludeRepositoriesText: String
  public var cacheMaxAgeSeconds: UInt64

  public init(
    authorsText: String = "",
    organizationsText: String = "",
    repositoriesText: String = "",
    excludeRepositoriesText: String = "",
    cacheMaxAgeSeconds: UInt64 = 600
  ) {
    self.authorsText = authorsText
    self.organizationsText = organizationsText
    self.repositoriesText = repositoriesText
    self.excludeRepositoriesText = excludeRepositoriesText
    self.cacheMaxAgeSeconds = cacheMaxAgeSeconds
  }

  public init(storedValue: String?) {
    guard
      let storedValue,
      !storedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let data = storedValue.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Storage.self, from: data)
    else {
      self.init()
      return
    }
    self.init(
      authorsText: decoded.authorsText ?? "",
      organizationsText: decoded.organizationsText ?? "",
      repositoriesText: decoded.repositoriesText ?? "",
      excludeRepositoriesText: decoded.excludeRepositoriesText ?? "",
      cacheMaxAgeSeconds: decoded.cacheMaxAgeSeconds ?? 600
    )
  }

  public func queryRequest(forceRefresh: Bool = false) -> ReviewsQueryRequest? {
    let organizations = Self.normalizedEntries(organizationsText)
    let repositories = Self.normalizedEntries(repositoriesText)
    guard !organizations.isEmpty || !repositories.isEmpty else {
      return nil
    }
    return ReviewsQueryRequest(
      authors: Self.normalizedEntries(authorsText),
      organizations: organizations,
      repositories: repositories,
      excludeRepositories: Self.normalizedEntries(excludeRepositoriesText),
      forceRefresh: forceRefresh,
      cacheMaxAgeSeconds: max(cacheMaxAgeSeconds, Self.minimumCacheMaxAgeSeconds)
    )
  }

  private static func normalizedEntries(_ text: String) -> [String] {
    text
      .split(whereSeparator: { $0 == "," || $0.isNewline })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .reduce(into: [String]()) { result, entry in
        if !result.contains(entry) {
          result.append(entry)
        }
      }
  }

  private struct Storage: Decodable {
    var authorsText: String?
    var organizationsText: String?
    var repositoriesText: String?
    var excludeRepositoriesText: String?
    var cacheMaxAgeSeconds: UInt64?
  }
}

public struct MobileRelayReviewsQueryPreferenceStore: @unchecked Sendable {
  private let defaults: UserDefaults
  private let storageKey: String

  public init(
    defaults: UserDefaults = .standard,
    storageKey: String = MobileRelayReviewsQueryPreferences.storageKey
  ) {
    self.defaults = defaults
    self.storageKey = storageKey
  }

  public func queryRequest(forceRefresh: Bool = false) -> ReviewsQueryRequest? {
    MobileRelayReviewsQueryPreferences(
      storedValue: defaults.string(forKey: storageKey)
    )
    .queryRequest(forceRefresh: forceRefresh)
  }
}
