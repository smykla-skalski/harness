import Foundation

/// Lightweight parser for the palette's query string. Returns a domain
/// scope derived from a leading `@token` prefix plus the remaining search
/// term. The parser is intentionally permissive: unknown tokens fall back
/// to the literal query so a user who types `@foo bar` still sees `@foo
/// bar` results across all domains.
public enum OpenAnythingQueryParser {
  public struct Parsed: Sendable, Equatable {
    public let scope: OpenAnythingDomain?
    public let term: String
    public let prefixConsumed: Bool

    public init(scope: OpenAnythingDomain?, term: String, prefixConsumed: Bool) {
      self.scope = scope
      self.term = term
      self.prefixConsumed = prefixConsumed
    }
  }

  /// Tokens accepted after the leading `@`. The mapping favors short forms
  /// so power users can type `@sess foo` instead of `@sessions foo`.
  public static let tokens: [String: OpenAnythingDomain] = [
    "actions": .actions,
    "action": .actions,
    "windows": .windows,
    "window": .windows,
    "settings": .settings,
    "sessions": .sessions,
    "session": .sessions,
    "sess": .sessions,
    "tasks": .taskBoard,
    "task": .taskBoard,
    "board": .taskBoard,
    "decisions": .decisions,
    "decision": .decisions,
    "reviews": .reviews,
    "review": .reviews,
    "pr": .reviews,
    "loaded": .loadedSession,
  ]

  public static func parse(_ raw: String) -> Parsed {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("@") else {
      return Parsed(scope: nil, term: trimmed, prefixConsumed: false)
    }
    let body = trimmed.dropFirst()
    guard let separator = body.firstIndex(where: \.isWhitespace) else {
      let token = normalizedToken(body)
      if let scope = tokens[token] {
        return Parsed(scope: scope, term: "", prefixConsumed: true)
      }
      return Parsed(scope: nil, term: trimmed, prefixConsumed: false)
    }
    let token = normalizedToken(body[..<separator])
    guard let scope = tokens[token] else {
      return Parsed(scope: nil, term: trimmed, prefixConsumed: false)
    }
    let rest = body[body.index(after: separator)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Parsed(scope: scope, term: rest, prefixConsumed: true)
  }

  private static func normalizedToken(_ raw: Substring) -> String {
    let token = raw.lowercased()
    guard token.hasSuffix(":") else { return token }
    return String(token.dropLast())
  }
}
