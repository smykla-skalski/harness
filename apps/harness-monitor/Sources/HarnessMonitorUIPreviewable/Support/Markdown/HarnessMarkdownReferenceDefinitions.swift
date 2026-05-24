import Foundation

enum HarnessMarkdownReferenceDefinitions {
  static func parse(in lines: [String]) -> [String: HarnessMarkdownReference] {
    lines.reduce(into: [:]) { references, line in
      guard let definition = definition(line) else { return }
      references[definition.label] = definition.reference
    }
  }

  static func definition(_ line: String) -> (label: String, reference: HarnessMarkdownReference)? {
    let trimmed = trimmingLeadingSpaces(line)
    guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { return nil }
    let afterClose = trimmed.index(after: close)
    guard afterClose < trimmed.endIndex, trimmed[afterClose] == ":" else { return nil }
    let label = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    guard !label.isEmpty else { return nil }
    let raw = String(trimmed[trimmed.index(after: afterClose)...])
      .trimmingCharacters(in: .whitespaces)
    guard !raw.isEmpty else { return nil }
    let parsed = destinationAndTitle(raw)
    return (label, HarnessMarkdownReference(destination: parsed.destination, title: parsed.title))
  }

  private static func destinationAndTitle(_ raw: String) -> (destination: String, title: String?) {
    if raw.hasPrefix("<"), let close = raw.firstIndex(of: ">") {
      let destination = String(raw[raw.index(after: raw.startIndex)..<close])
      return (destination, title(String(raw[raw.index(after: close)...])))
    }
    guard let split = raw.firstIndex(where: \.isWhitespace) else { return (raw, nil) }
    return (String(raw[..<split]), title(String(raw[split...])))
  }

  private static func title(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return nil }
    if (first == "\"" && last == "\"") || (first == "'" && last == "'")
      || (first == "(" && last == ")")
    {
      return String(trimmed.dropFirst().dropLast())
    }
    return nil
  }

  private static func trimmingLeadingSpaces(_ line: String) -> String {
    String(line.drop { $0 == " " || $0 == "\t" })
  }
}
