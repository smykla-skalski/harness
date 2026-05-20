import Foundation

enum SettingsGitHubRepositoryNormalization {
  static func normalized(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func repository(owner: String, repo: String) -> String? {
    guard let owner = normalized(owner), let repo = normalized(repo), !repo.contains("/") else {
      return nil
    }
    return "\(owner.lowercased())/\(repo.lowercased())"
  }

  static func repositoryEntry(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return nil
    }
    let parts = trimmed.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 2 else {
      return trimmed.lowercased()
    }
    let owner = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
    let repo = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    guard let repository = repository(owner: owner, repo: repo) else {
      return trimmed.lowercased()
    }
    return repository
  }

  static func repositories(from value: String) -> [String] {
    var repositories: [String] = []
    var seen: Set<String> = []
    for entry in value.split(whereSeparator: \.isNewline) {
      guard let repository = repositoryEntry(String(entry)) else {
        continue
      }
      let key = repository.lowercased()
      if seen.insert(key).inserted {
        repositories.append(repository)
      }
    }
    return repositories
  }
}
