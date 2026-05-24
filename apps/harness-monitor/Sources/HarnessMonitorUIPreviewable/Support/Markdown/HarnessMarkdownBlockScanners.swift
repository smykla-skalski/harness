import Foundation

struct FenceStart {
  let marker: Character
  let count: Int
  let info: String
}

struct UnorderedMarker {
  let content: String
  let checkbox: Bool?
  let checkboxMarkerColumn: Int?
}

func fenceStart(_ line: String) -> FenceStart? {
  let trimmed = line.trimmingLeadingSpaces()
  guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
  let count = trimmed.prefix { $0 == marker }.count
  guard count >= 3 else { return nil }
  let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
  return FenceStart(marker: marker, count: count, info: info)
}

func fenceClose(_ line: String, fence: FenceStart) -> Bool {
  let trimmed = line.trimmingLeadingSpaces()
  let run = trimmed.prefix { $0 == fence.marker }.count
  guard run >= fence.count else { return false }
  return trimmed.dropFirst(run).allSatisfy { $0.isWhitespace }
}

func heading(
  _ line: String,
  references: [String: HarnessMarkdownReference] = [:]
) -> HarnessMarkdownBlock? {
  let trimmed = line.trimmingLeadingSpaces()
  let level = trimmed.prefix { $0 == "#" }.count
  guard (1...6).contains(level), trimmed.dropFirst(level).first?.isWhitespace == true else {
    return nil
  }
  let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
  return .heading(
    level: level, inlines: HarnessMarkdownInlineParser.parse(text, references: references))
}

func isThematicBreak(_ line: String) -> Bool {
  let compact = line.filter { !$0.isWhitespace }
  guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else {
    return false
  }
  return compact.allSatisfy { $0 == first }
}

func unorderedMarker(_ line: String) -> UnorderedMarker? {
  let trimmed = line.trimmingLeadingSpaces()
  guard let marker = trimmed.first, trimmed.count >= 2, ["-", "*", "+"].contains(marker),
    trimmed.dropFirst().first?.isWhitespace == true
  else {
    return nil
  }
  let (content, checkbox) = checkboxContent(String(trimmed.dropFirst(2)))
  let leadingByteCount = line.utf8.prefix { $0 == 0x20 || $0 == 0x09 }.count
  let checkboxMarkerColumn: Int? = checkbox == nil ? nil : leadingByteCount + 3
  return UnorderedMarker(
    content: content,
    checkbox: checkbox,
    checkboxMarkerColumn: checkboxMarkerColumn
  )
}

func unorderedListContentByteOffset(in line: String, hasCheckbox: Bool) -> Int {
  let leadingByteCount = line.utf8.prefix { $0 == 0x20 || $0 == 0x09 }.count
  return leadingByteCount + 2 + (hasCheckbox ? 4 : 0)
}

func orderedListContentByteOffset(in line: String) -> Int {
  let utf8 = line.utf8
  let leadingByteCount = utf8.prefix { $0 == 0x20 || $0 == 0x09 }.count
  let digitBytes = utf8.dropFirst(leadingByteCount).prefix { (0x30...0x39).contains($0) }.count
  return leadingByteCount + digitBytes + 2
}

func orderedMarker(_ line: String) -> (number: Int, content: String)? {
  let trimmed = line.trimmingLeadingSpaces()
  var digits = ""
  var cursor = trimmed.startIndex
  while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
    digits.append(trimmed[cursor])
    cursor = trimmed.index(after: cursor)
  }
  guard !digits.isEmpty, cursor < trimmed.endIndex, trimmed[cursor] == "." || trimmed[cursor] == ")"
  else {
    return nil
  }
  let afterMarker = trimmed.index(after: cursor)
  guard afterMarker < trimmed.endIndex, trimmed[afterMarker].isWhitespace else { return nil }
  return (Int(digits) ?? 1, String(trimmed[trimmed.index(after: afterMarker)...]))
}

func checkboxContent(_ raw: String) -> (content: String, checkbox: Bool?) {
  guard raw.count >= 4, raw.first == "[" else { return (raw, nil) }
  let marker = raw.dropFirst().first
  let close = raw.dropFirst(2).first
  guard close == "]", raw.dropFirst(3).first?.isWhitespace == true else { return (raw, nil) }
  let checked = marker == "x" || marker == "X"
  return (String(raw.dropFirst(4)), marker == " " || checked ? checked : nil)
}

func isTableSeparator(_ line: String) -> Bool {
  let cells = splitTableRow(line)
  guard !cells.isEmpty else { return false }
  return cells.allSatisfy { cell in
    let compact = cell.trimmingCharacters(in: .whitespaces)
    let core = compact.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return core.count >= 3 && core.allSatisfy { $0 == "-" }
  }
}

func tableAlignments(_ line: String) -> [HarnessMarkdownTable.Alignment] {
  splitTableRow(line).map { cell in
    let trimmed = cell.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix(":"), trimmed.hasSuffix(":") { return .center }
    if trimmed.hasSuffix(":") { return .trailing }
    return .leading
  }
}

func splitTableRow(_ line: String) -> [String] {
  var trimmed = line.trimmingCharacters(in: .whitespaces)
  if trimmed.first == "|" { trimmed.removeFirst() }
  if trimmed.last == "|" { trimmed.removeLast() }
  return trimmed.split(separator: "|", omittingEmptySubsequences: false)
    .map { String($0).trimmingCharacters(in: .whitespaces) }
}

func isHTML(_ line: String) -> Bool {
  let trimmed = line.trimmingLeadingSpaces()
  return trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.count > 2
}

func githubAlertKind(_ line: String) -> HarnessMarkdownAlert.Kind? {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  guard trimmed.hasPrefix("[!"), trimmed.last == "]", trimmed.count > 3 else {
    return nil
  }
  let marker = String(trimmed.dropFirst(2).dropLast())
  return HarnessMarkdownAlert.Kind(marker: marker)
}

func legacyGitHubAlert(_ line: String) -> (kind: HarnessMarkdownAlert.Kind, remainder: String)? {
  let trimmed = line.trimmingCharacters(in: .whitespaces)
  let withoutEmoji = droppingLeadingMarkdownAlertEmoji(from: trimmed)
  for kind in HarnessMarkdownAlert.Kind.allCases {
    for pattern in legacyGitHubAlertLabelPatterns(for: kind.title) {
      guard withoutEmoji.lowercased().hasPrefix(pattern.lowercased()) else { continue }
      let remainder = String(withoutEmoji.dropFirst(pattern.count))
      return (kind, trimLegacyGitHubAlertRemainder(remainder))
    }
  }
  return nil
}

private func legacyGitHubAlertLabelPatterns(for title: String) -> [String] {
  [
    "**\(title)**",
    "**\(title)**:",
    "**\(title):**",
    title,
    "\(title):",
  ]
}

private func droppingLeadingMarkdownAlertEmoji(from line: String) -> String {
  let characters = Array(line)
  guard let first = characters.first, isMarkdownAlertEmoji(first) else { return line }
  let restStart = characters.index(after: characters.startIndex)
  guard restStart < characters.endIndex, characters[restStart].isWhitespace else { return line }
  return String(characters[restStart...]).trimmingCharacters(in: .whitespaces)
}

private func trimLegacyGitHubAlertRemainder(_ raw: String) -> String {
  var trimmed = raw.trimmingCharacters(in: .whitespaces)
  while let first = trimmed.first, [":", "-", "—", "–"].contains(first) {
    trimmed.removeFirst()
    trimmed = trimmed.trimmingCharacters(in: .whitespaces)
  }
  return trimmed
}

private func isMarkdownAlertEmoji(_ character: Character) -> Bool {
  character.unicodeScalars.contains { scalar in
    scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
  }
}

func isSingleLineHTML(_ line: String) -> Bool {
  line.contains("</") || line.hasPrefix("<!--") && line.contains("-->")
}
