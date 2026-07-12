import Foundation

public struct MobileMirrorSecretRedactor: Sendable {
  private struct Rule: @unchecked Sendable {
    var expression: NSRegularExpression
    var template: String
  }

  private struct RawRule {
    var pattern: String
    var options: NSRegularExpression.Options
    var template: String
  }

  public init() {}

  public func redact(_ value: String) -> String {
    guard !value.isEmpty else {
      return value
    }
    return Self.rules.reduce(value) { partial, rule in
      let range = NSRange(partial.startIndex..<partial.endIndex, in: partial)
      return rule.expression.stringByReplacingMatches(
        in: partial,
        options: [],
        range: range,
        withTemplate: rule.template
      )
    }
  }

  private static let rules: [Rule] = rawRules.map { rule in
    guard
      let expression = try? NSRegularExpression(
        pattern: rule.pattern,
        options: rule.options
      )
    else {
      fatalError("Invalid redaction rule pattern: \(rule.pattern)")
    }
    return Rule(expression: expression, template: rule.template)
  }

  private static let rawRules: [RawRule] = [
    .init(
      pattern:
        "(?i)(\\b(?:aws_secret_access_key|aws_access_key_id|github_token|gh_token"
        + "|gitlab_token|openai_api_key|anthropic_api_key|api[_-]?key"
        + "|access[_-]?token|refresh[_-]?token|auth[_-]?token|id[_-]?token"
        + "|client[_-]?secret|private[_-]?key|secret|password|passwd|pwd)"
        + "\\b\\s*[:=]\\s*)(\"[^\"]*\"|'[^']*'|[^\\s,;]+)",
      options: [],
      template: "$1[redacted]"
    ),
    .init(
      pattern: "(?i)\\bBearer\\s+[A-Za-z0-9._~+/=-]{8,}",
      options: [],
      template: "Bearer [redacted]"
    ),
    .init(
      pattern: "(?i)(https?://)[^\\s/@]+:[^\\s/@]+@",
      options: [],
      template: "$1[redacted]@"
    ),
    .init(
      pattern: "\\bgithub_pat_[A-Za-z0-9_]{20,}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern: "\\bgh[pousr]_[A-Za-z0-9_]{20,}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern: "\\bglpat-[A-Za-z0-9_-]{20,}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern: "\\bsk-[A-Za-z0-9]{20,}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern: "\\bxox[baprs]-[A-Za-z0-9-]{20,}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern: "\\bAKIA[0-9A-Z]{16}\\b",
      options: [],
      template: "[redacted]"
    ),
    .init(
      pattern:
        "-----BEGIN [^-]*(?:PRIVATE KEY|SECRET|TOKEN)[\\s\\S]*?-----END [^-]*-----",
      options: [.caseInsensitive],
      template: "[redacted]"
    ),
  ]
}
