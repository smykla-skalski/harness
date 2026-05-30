import Foundation

struct GitHubPullRequestReference: Codable, Equatable, Hashable, Identifiable, Sendable {
  let repository: String
  let number: UInt64
  let rawMatch: String

  var id: String { "\(repository.lowercased())#\(number)" }

  var displayText: String {
    "\(repository)#\(number)"
  }

  var canonicalURLString: String {
    "https://github.com/\(repository)/pull/\(number)"
  }
}

enum GitHubPullRequestReferenceParser {
  static func references(in text: String) -> [GitHubPullRequestReference] {
    let normalized = normalize(text)
    var collector = ReferenceCollector()
    collector.collect(pattern: githubURLPattern, in: normalized)
    collector.collect(pattern: shorthandPattern, in: normalized)
    return collector.references
  }

  private static let githubURLPattern =
    [
      #"(?i)(?:https?://)?(?:www\.)?github\.com/"#,
      #"([A-Za-z0-9][A-Za-z0-9_.-]*)/"#,
      #"([A-Za-z0-9][A-Za-z0-9_.-]*)/pull/([0-9]+)"#,
      #"(?:[/?#][^\s<>\]\)]*)?"#,
    ].joined()

  private static let shorthandPattern =
    #"(?i)(?<![A-Za-z0-9_.-])([A-Za-z0-9][A-Za-z0-9_.-]*)/([A-Za-z0-9][A-Za-z0-9_.-]*)#([0-9]+)(?![0-9])"#

  private static func normalize(_ text: String) -> String {
    var normalized = text.replacingOccurrences(of: "\u{00A0}", with: " ")
    normalized = replacing(pattern: #"(?i)https?:\s+//"#, in: normalized, with: "https://")
    normalized = replacing(pattern: #"(?i)github\.\s+com"#, in: normalized, with: "github.com")
    normalized = replacing(
      pattern: #"/\s+(pull|files|commits|checks)"#, in: normalized, with: "/$1")
    normalized = replacing(pattern: #"\s+(/(?:files|commits|checks))"#, in: normalized, with: "$1")
    return normalized
  }

  private static func replacing(pattern: String, in text: String, with replacement: String)
    -> String
  {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return text
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.stringByReplacingMatches(
      in: text,
      range: range,
      withTemplate: replacement
    )
  }
}

private struct ReferenceCollector {
  private(set) var references: [GitHubPullRequestReference] = []
  private var seen = Set<String>()

  mutating func collect(pattern: String, in text: String) {
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return
    }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    for match in regex.matches(in: text, range: range) {
      append(match: match, text: text)
    }
  }

  private mutating func append(match: NSTextCheckingResult, text: String) {
    guard
      let owner = capture(match, at: 1, in: text),
      let repo = capture(match, at: 2, in: text),
      let numberText = capture(match, at: 3, in: text),
      let number = UInt64(numberText)
    else {
      return
    }
    let repository = "\(owner)/\(repo)"
    let key = "\(repository.lowercased())#\(number)"
    guard seen.insert(key).inserted else {
      return
    }
    references.append(
      GitHubPullRequestReference(
        repository: repository,
        number: number,
        rawMatch: capture(match, at: 0, in: text) ?? repository
      )
    )
  }

  private func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
    guard index < match.numberOfRanges else {
      return nil
    }
    let range = match.range(at: index)
    guard range.location != NSNotFound, let stringRange = Range(range, in: text) else {
      return nil
    }
    return String(text[stringRange])
  }
}
