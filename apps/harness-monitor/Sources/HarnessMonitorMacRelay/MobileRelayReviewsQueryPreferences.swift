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

public enum MobileRelayGitRepositoryDiscovery {
  public static func repositories(
    from sessions: [SessionSummary],
    fileManager: FileManager = .default
  ) -> [String] {
    sessions
      .filter { $0.status != .ended }
      .flatMap { session in
        repositories(checkoutRoot: session.checkoutRoot, fileManager: fileManager)
      }
      .deduplicatedPreservingOrder()
  }

  static func repositories(
    checkoutRoot: String,
    fileManager: FileManager = .default
  ) -> [String] {
    let trimmedRoot = checkoutRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedRoot.isEmpty else {
      return []
    }
    let rootURL = URL(fileURLWithPath: trimmedRoot, isDirectory: true)
    return gitConfigURLs(checkoutRoot: rootURL, fileManager: fileManager)
      .flatMap(remoteURLs(in:))
      .compactMap(repositorySlug(fromRemoteURL:))
      .deduplicatedPreservingOrder()
  }

  static func repositorySlug(fromRemoteURL remoteURL: String) -> String? {
    let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }

    if let url = URL(string: trimmed),
      let host = url.host?.lowercased(),
      host == "github.com" || host == "www.github.com"
    {
      return repositorySlug(fromGitHubPath: url.path)
    }

    let lowercased = trimmed.lowercased()
    let scpPrefix = "git@github.com:"
    if lowercased.hasPrefix(scpPrefix) {
      return repositorySlug(fromGitHubPath: String(trimmed.dropFirst(scpPrefix.count)))
    }

    let sshPrefix = "ssh://git@github.com/"
    if lowercased.hasPrefix(sshPrefix) {
      return repositorySlug(fromGitHubPath: String(trimmed.dropFirst(sshPrefix.count)))
    }

    return nil
  }

  private static func gitConfigURLs(
    checkoutRoot: URL,
    fileManager: FileManager
  ) -> [URL] {
    let dotGit = checkoutRoot.appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
      return []
    }

    if isDirectory.boolValue {
      return [dotGit.appendingPathComponent("config", isDirectory: false)]
    }

    guard let gitDir = gitDirectory(fromGitFile: dotGit, relativeTo: checkoutRoot) else {
      return []
    }
    var configURLs = [gitDir.appendingPathComponent("config", isDirectory: false)]
    if let commonDir = commonDirectory(from: gitDir) {
      configURLs.append(commonDir.appendingPathComponent("config", isDirectory: false))
    }
    return configURLs
  }

  private static func gitDirectory(fromGitFile url: URL, relativeTo checkoutRoot: URL) -> URL? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
      return nil
    }
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedLine.lowercased().hasPrefix("gitdir:") else {
        continue
      }
      let path = trimmedLine.dropFirst("gitdir:".count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return resolvedURL(path: path, relativeTo: checkoutRoot)
    }
    return nil
  }

  private static func commonDirectory(from gitDir: URL) -> URL? {
    let commonDirFile = gitDir.appendingPathComponent("commondir", isDirectory: false)
    guard let contents = try? String(contentsOf: commonDirFile, encoding: .utf8) else {
      return nil
    }
    let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else {
      return nil
    }
    return resolvedURL(path: path, relativeTo: gitDir)
  }

  private static func resolvedURL(path: String, relativeTo baseURL: URL) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path, isDirectory: true)
    }
    return baseURL.appendingPathComponent(path, isDirectory: true).standardizedFileURL
  }

  private static func remoteURLs(in configURL: URL) -> [String] {
    guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
      return []
    }
    var urls: [String] = []
    var insideRemoteSection = false
    for line in contents.split(whereSeparator: \.isNewline) {
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLine.hasPrefix("[") {
        insideRemoteSection = trimmedLine.lowercased().hasPrefix("[remote ")
        continue
      }
      guard insideRemoteSection else {
        continue
      }
      let parts = trimmedLine.split(separator: "=", maxSplits: 1)
      guard parts.count == 2,
        parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "url"
      else {
        continue
      }
      urls.append(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return urls
  }

  private static func repositorySlug(fromGitHubPath path: String) -> String? {
    let components = path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .split(separator: "/")
      .map(String.init)
    guard components.count >= 2 else {
      return nil
    }
    let owner = components[0]
    let repository = components[1].removingSuffix(".git")
    guard isSafeGitHubPathComponent(owner),
      isSafeGitHubPathComponent(repository)
    else {
      return nil
    }
    return "\(owner)/\(repository)"
  }

  private static func isSafeGitHubPathComponent(_ component: String) -> Bool {
    guard !component.isEmpty else {
      return false
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
    return component.unicodeScalars.allSatisfy { allowed.contains($0) }
  }
}

extension Array where Element: Hashable {
  fileprivate func deduplicatedPreservingOrder() -> [Element] {
    var seen = Set<Element>()
    return filter { seen.insert($0).inserted }
  }
}

extension String {
  fileprivate func removingSuffix(_ suffix: String) -> String {
    hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
  }
}
