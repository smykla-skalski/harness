import Foundation

struct ReviewFilesGeneratedCompiledPattern {
  private let regex: NSRegularExpression

  init?(_ pattern: String) {
    let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if Self.looksLikeLegacyRegex(trimmed),
      let legacyRegex = try? NSRegularExpression(pattern: trimmed)
    {
      regex = legacyRegex
      return
    }

    let globRegex = Self.globRegex(from: trimmed)
    guard let compiledGlobRegex = try? NSRegularExpression(pattern: globRegex) else {
      return nil
    }
    regex = compiledGlobRegex
  }

  func matches(_ path: String) -> Bool {
    let range = NSRange(path.startIndex..., in: path)
    return regex.firstMatch(in: path, range: range) != nil
  }

  private static func looksLikeLegacyRegex(_ pattern: String) -> Bool {
    pattern.contains("\\") || pattern.contains("^") || pattern.contains("$")
      || pattern.contains("(") || pattern.contains(")") || pattern.contains("|")
      || pattern.contains("[") || pattern.contains("]")
  }

  private static func globRegex(from pattern: String) -> String {
    var normalizedPattern = pattern
    if normalizedPattern.hasSuffix("/") {
      normalizedPattern += "**"
    }
    if !normalizedPattern.contains("/") {
      normalizedPattern = "**/\(normalizedPattern)"
    }

    var regex = "^"
    var index = normalizedPattern.startIndex
    while index < normalizedPattern.endIndex {
      let character = normalizedPattern[index]
      if character == "*" {
        let next = normalizedPattern.index(after: index)
        if next < normalizedPattern.endIndex, normalizedPattern[next] == "*" {
          let afterDoubleStar = normalizedPattern.index(after: next)
          if afterDoubleStar < normalizedPattern.endIndex,
            normalizedPattern[afterDoubleStar] == "/"
          {
            regex += "(?:[^/]+/)*"
            index = normalizedPattern.index(after: afterDoubleStar)
          } else {
            regex += ".*"
            index = afterDoubleStar
          }
        } else {
          regex += "[^/]*"
          index = next
        }
        continue
      }

      if character == "?" {
        regex += "[^/]"
        index = normalizedPattern.index(after: index)
        continue
      }

      regex += escapedRegexLiteral(character)
      index = normalizedPattern.index(after: index)
    }

    regex += "$"
    return regex
  }

  private static func escapedRegexLiteral(_ character: Character) -> String {
    switch character {
    case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
      "\\\(character)"
    default:
      String(character)
    }
  }
}
