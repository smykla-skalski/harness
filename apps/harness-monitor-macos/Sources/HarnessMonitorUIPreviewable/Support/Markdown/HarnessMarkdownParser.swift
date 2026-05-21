import Foundation

enum HarnessMarkdownParser {
  static func parse(_ markdown: String) -> HarnessMarkdownDocument {
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var parser = HarnessMarkdownBlockParser(lines: lines)
    return HarnessMarkdownDocument(blocks: parser.parseBlocks())
  }
}

private struct HarnessMarkdownBlockParser {
  private let lines: [String]
  private var index = 0

  init(lines: [String]) {
    self.lines = lines
  }

  mutating func parseBlocks() -> [HarnessMarkdownBlock] {
    var blocks: [HarnessMarkdownBlock] = []
    while index < lines.count {
      let line = lines[index]
      if line.isBlank {
        index += 1
      } else if let fence = fenceStart(line) {
        blocks.append(parseFencedCode(fence))
      } else if line.leadingSpaceCount >= 4 {
        blocks.append(parseIndentedCode())
      } else if let heading = heading(line) {
        blocks.append(heading)
        index += 1
      } else if isThematicBreak(line) {
        blocks.append(.thematicBreak)
        index += 1
      } else if line.trimmingLeadingSpaces().hasPrefix(">") {
        blocks.append(parseBlockQuote())
      } else if unorderedMarker(line) != nil {
        blocks.append(parseUnorderedList())
      } else if orderedMarker(line) != nil {
        blocks.append(parseOrderedList())
      } else if isTableStart(at: index) {
        blocks.append(parseTable())
      } else if isHTML(line) {
        blocks.append(.html(line.trimmingLeadingSpaces()))
        index += 1
      } else {
        blocks.append(parseParagraph())
      }
    }
    return blocks
  }

  private mutating func parseFencedCode(_ fence: FenceStart) -> HarnessMarkdownBlock {
    index += 1
    var body: [String] = []
    while index < lines.count {
      if fenceClose(lines[index], fence: fence) {
        index += 1
        break
      }
      body.append(lines[index])
      index += 1
    }
    let source = body.joined(separator: "\n")
    let language = HarnessCodeLanguage(infoString: fence.info)
    return .codeBlock(
      language: language,
      source: source,
      tokens: HarnessCodeHighlighter.highlight(source, language: language)
    )
  }

  private mutating func parseIndentedCode() -> HarnessMarkdownBlock {
    var body: [String] = []
    while index < lines.count, lines[index].isBlank || lines[index].leadingSpaceCount >= 4 {
      body.append(lines[index].droppingLeadingSpaces(4))
      index += 1
    }
    let source = body.joined(separator: "\n")
    return .codeBlock(language: .generic, source: source, tokens: HarnessCodeHighlighter.highlight(source, language: .generic))
  }

  private mutating func parseBlockQuote() -> HarnessMarkdownBlock {
    var quoteLines: [String] = []
    while index < lines.count {
      let trimmed = lines[index].trimmingLeadingSpaces()
      guard trimmed.hasPrefix(">") else { break }
      var content = String(trimmed.dropFirst())
      if content.hasPrefix(" ") { content.removeFirst() }
      quoteLines.append(content)
      index += 1
    }
    var parser = HarnessMarkdownBlockParser(lines: quoteLines)
    return .blockQuote(parser.parseBlocks())
  }

  private mutating func parseUnorderedList() -> HarnessMarkdownBlock {
    var items: [HarnessMarkdownListItem] = []
    while index < lines.count, let marker = unorderedMarker(lines[index]) {
      index += 1
      items.append(parseListItem(firstLine: marker.content, checkbox: marker.checkbox))
    }
    return .unorderedList(items)
  }

  private mutating func parseOrderedList() -> HarnessMarkdownBlock {
    let start = orderedMarker(lines[index])?.number ?? 1
    var items: [HarnessMarkdownListItem] = []
    while index < lines.count, let marker = orderedMarker(lines[index]) {
      index += 1
      items.append(parseListItem(firstLine: marker.content, checkbox: nil))
    }
    return .orderedList(start: start, items: items)
  }

  private mutating func parseListItem(firstLine: String, checkbox: Bool?) -> HarnessMarkdownListItem {
    var itemLines = [firstLine]
    while index < lines.count {
      if lines[index].isBlank {
        itemLines.append("")
        index += 1
      } else if lines[index].leadingSpaceCount >= 2 {
        itemLines.append(lines[index].droppingLeadingSpaces(2))
        index += 1
      } else {
        break
      }
    }
    var parser = HarnessMarkdownBlockParser(lines: itemLines)
    return HarnessMarkdownListItem(checkbox: checkbox, blocks: parser.parseBlocks())
  }

  private mutating func parseTable() -> HarnessMarkdownBlock {
    let headers = splitTableRow(lines[index]).map(HarnessMarkdownInlineParser.parse)
    index += 2
    var rows: [[[HarnessMarkdownInline]]] = []
    while index < lines.count, lines[index].contains("|"), !lines[index].isBlank {
      rows.append(splitTableRow(lines[index]).map(HarnessMarkdownInlineParser.parse))
      index += 1
    }
    return .table(HarnessMarkdownTable(headers: headers, rows: rows))
  }

  private mutating func parseParagraph() -> HarnessMarkdownBlock {
    var body: [String] = []
    while index < lines.count, !lines[index].isBlank, !startsBlock(lines[index], at: index) {
      body.append(lines[index].trimmingLeadingSpaces())
      index += 1
    }
    return .paragraph(HarnessMarkdownInlineParser.parse(body.joined(separator: "\n")))
  }

  private func startsBlock(_ line: String, at lineIndex: Int) -> Bool {
    fenceStart(line) != nil
      || line.leadingSpaceCount >= 4
      || heading(line) != nil
      || isThematicBreak(line)
      || line.trimmingLeadingSpaces().hasPrefix(">")
      || unorderedMarker(line) != nil
      || orderedMarker(line) != nil
      || isTableStart(at: lineIndex)
      || isHTML(line)
  }

  private func isTableStart(at lineIndex: Int) -> Bool {
    lineIndex + 1 < lines.count
      && lines[lineIndex].contains("|")
      && isTableSeparator(lines[lineIndex + 1])
  }
}

private struct FenceStart {
  let marker: Character
  let count: Int
  let info: String
}

private func fenceStart(_ line: String) -> FenceStart? {
  let trimmed = line.trimmingLeadingSpaces()
  guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
  let count = trimmed.prefix { $0 == marker }.count
  guard count >= 3 else { return nil }
  let info = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
  return FenceStart(marker: marker, count: count, info: info)
}

private func fenceClose(_ line: String, fence: FenceStart) -> Bool {
  let trimmed = line.trimmingLeadingSpaces()
  guard trimmed.prefix(fence.count).allSatisfy({ $0 == fence.marker }) else { return false }
  return trimmed.dropFirst(fence.count).allSatisfy(\.isWhitespace)
}

private func heading(_ line: String) -> HarnessMarkdownBlock? {
  let trimmed = line.trimmingLeadingSpaces()
  let level = trimmed.prefix { $0 == "#" }.count
  guard (1...6).contains(level), trimmed.dropFirst(level).first?.isWhitespace == true else {
    return nil
  }
  let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
  return .heading(level: level, inlines: HarnessMarkdownInlineParser.parse(text))
}

private func isThematicBreak(_ line: String) -> Bool {
  let compact = line.filter { !$0.isWhitespace }
  guard compact.count >= 3, let first = compact.first, ["-", "*", "_"].contains(first) else {
    return false
  }
  return compact.allSatisfy { $0 == first }
}

private func unorderedMarker(_ line: String) -> (content: String, checkbox: Bool?)? {
  let trimmed = line.trimmingLeadingSpaces()
  guard trimmed.count >= 2, ["-", "*", "+"].contains(trimmed.first!), trimmed.dropFirst().first?.isWhitespace == true else {
    return nil
  }
  return checkboxContent(String(trimmed.dropFirst(2)))
}

private func orderedMarker(_ line: String) -> (number: Int, content: String)? {
  let trimmed = line.trimmingLeadingSpaces()
  var digits = ""
  var cursor = trimmed.startIndex
  while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
    digits.append(trimmed[cursor])
    cursor = trimmed.index(after: cursor)
  }
  guard !digits.isEmpty, cursor < trimmed.endIndex, trimmed[cursor] == "." else { return nil }
  let afterDot = trimmed.index(after: cursor)
  guard afterDot < trimmed.endIndex, trimmed[afterDot].isWhitespace else { return nil }
  return (Int(digits) ?? 1, String(trimmed[trimmed.index(after: afterDot)...]))
}

private func checkboxContent(_ raw: String) -> (content: String, checkbox: Bool?) {
  guard raw.count >= 4, raw.first == "[" else { return (raw, nil) }
  let marker = raw.dropFirst().first
  let close = raw.dropFirst(2).first
  guard close == "]", raw.dropFirst(3).first?.isWhitespace == true else { return (raw, nil) }
  let checked = marker == "x" || marker == "X"
  return (String(raw.dropFirst(4)), marker == " " || checked ? checked : nil)
}

private func isTableSeparator(_ line: String) -> Bool {
  let cells = splitTableRow(line)
  guard !cells.isEmpty else { return false }
  return cells.allSatisfy { cell in
    let compact = cell.trimmingCharacters(in: .whitespaces)
    let core = compact.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return core.count >= 3 && core.allSatisfy { $0 == "-" }
  }
}

private func splitTableRow(_ line: String) -> [String] {
  var trimmed = line.trimmingCharacters(in: .whitespaces)
  if trimmed.first == "|" { trimmed.removeFirst() }
  if trimmed.last == "|" { trimmed.removeLast() }
  return trimmed.split(separator: "|", omittingEmptySubsequences: false)
    .map { String($0).trimmingCharacters(in: .whitespaces) }
}

private func isHTML(_ line: String) -> Bool {
  let trimmed = line.trimmingLeadingSpaces()
  return trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.count > 2
}

extension String {
  fileprivate var isBlank: Bool {
    allSatisfy(\.isWhitespace)
  }

  fileprivate var leadingSpaceCount: Int {
    prefix { $0 == " " }.count
  }

  fileprivate func trimmingLeadingSpaces() -> String {
    String(drop { $0 == " " || $0 == "\t" })
  }

  fileprivate func droppingLeadingSpaces(_ count: Int) -> String {
    var dropped = 0
    var cursor = startIndex
    while cursor < endIndex, dropped < count, self[cursor] == " " {
      cursor = index(after: cursor)
      dropped += 1
    }
    return String(self[cursor...])
  }
}
