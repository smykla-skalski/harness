import Foundation

public enum DependencyUpdateBot: String, Codable, Sendable, CaseIterable {
  case renovate
  case dependabot

  public static func detect(authorLogin: String) -> DependencyUpdateBot? {
    let normalized = authorLogin.lowercased()
    if normalized == "renovate[bot]" || normalized == "renovate-bot" {
      return .renovate
    }
    if normalized == "dependabot[bot]" {
      return .dependabot
    }
    return nil
  }

  public var rebaseCommentBody: String {
    switch self {
    case .renovate: "@renovatebot rebase"
    case .dependabot: "@dependabot recreate"
    }
  }

  public var rebaseActionTitle: String {
    switch self {
    case .renovate: "Rebase via Renovate"
    case .dependabot: "Recreate via Dependabot"
    }
  }
}
