import Foundation

struct DashboardOCRProcessedText: Equatable {
  let rawText: String
  let displayText: String
  let sourceProfile: DashboardOCRTextSourceProfile
}

enum DashboardOCRTextSourceProfile: String, Equatable {
  case generic
  case slack
}

enum DashboardOCRTextPostProcessor {
  static func process(
    _ rawText: String,
    sourceMetadata: [DashboardOCRImageSourceMetadata]
  ) -> DashboardOCRProcessedText {
    let profile = sourceProfile(rawText: rawText, sourceMetadata: sourceMetadata)
    let lines = normalizedLines(from: rawText, profile: profile)
    return DashboardOCRProcessedText(
      rawText: rawText,
      displayText: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
      sourceProfile: profile
    )
  }

  private static func sourceProfile(
    rawText: String,
    sourceMetadata: [DashboardOCRImageSourceMetadata]
  ) -> DashboardOCRTextSourceProfile {
    let sourceText =
      sourceMetadata
      .flatMap { [$0.name, $0.detail ?? ""] }
      .joined(separator: "\n")
      .lowercased()
    if sourceText.contains("slack") || rawText.lowercased().contains("slack") {
      return .slack
    }
    return .generic
  }

  private static func normalizedLines(
    from rawText: String,
    profile: DashboardOCRTextSourceProfile
  ) -> [String] {
    let lines =
      rawText
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { normalizeLine(String($0), profile: profile) }
    return collapsedBlankLines(deduplicatedConsecutiveLines(lines))
  }

  private static func normalizeLine(
    _ line: String,
    profile: DashboardOCRTextSourceProfile
  ) -> String {
    var normalized =
      line
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    normalized = normalizeURLs(in: normalized)
    if profile == .slack {
      normalized = normalizeSlackBullet(in: normalized)
    }
    return normalized
  }

  private static func normalizeURLs(in line: String) -> String {
    guard line.localizedCaseInsensitiveContains("http") else {
      return line
    }
    var normalized = line
    let replacements = [
      (#"(?i)\b(https?)\s*:\s*/\s*/\s*"#, "$1://"),
      (#"(?<=\w)\s*\.\s*(?=\w)"#, "."),
      (#"\s+\.\s*"#, "."),
      (#"\s*/\s*"#, "/"),
      (#"\s+#\s*"#, "#"),
      (#"\s+\?\s*"#, "?"),
      (#"\s+&\s*"#, "&"),
      (#"\s+=\s*"#, "="),
    ]
    for replacement in replacements {
      normalized = normalized.replacingOccurrences(
        of: replacement.0,
        with: replacement.1,
        options: .regularExpression
      )
    }
    return normalized
  }

  private static func normalizeSlackBullet(in line: String) -> String {
    line.replacingOccurrences(
      of: #"^[•·*]\s*(https?://)"#,
      with: "• $1",
      options: .regularExpression
    )
  }

  private static func deduplicatedConsecutiveLines(_ lines: [String]) -> [String] {
    var output: [String] = []
    for line in lines where output.last != line {
      output.append(line)
    }
    return output
  }

  private static func collapsedBlankLines(_ lines: [String]) -> [String] {
    var output: [String] = []
    var previousWasBlank = false
    for line in lines {
      let isBlank = line.isEmpty
      guard !(isBlank && previousWasBlank) else {
        continue
      }
      output.append(line)
      previousWasBlank = isBlank
    }
    return output
  }
}
