import Foundation

public enum ReviewBot: String, Codable, Sendable, CaseIterable {
  case renovate
  case dependabot

  public static func detect(authorLogin: String) -> Self? {
    let normalized = authorLogin
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    if normalized == "renovate[bot]" || normalized == "renovate-bot" || normalized == "renovate" {
      return .renovate
    }
    if normalized == "dependabot[bot]" || normalized == "dependabot" {
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
