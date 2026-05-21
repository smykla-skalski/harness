import Foundation

enum HarnessMarkdownParser {
  static func parse(
    _ markdown: String,
    shouldCancel: @escaping @Sendable () -> Bool = { false }
  ) -> HarnessMarkdownDocument {
    guard !shouldCancel() else { return .empty }
    let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let references = HarnessMarkdownReferenceDefinitions.parse(in: lines)
    var parser = HarnessMarkdownBlockParser(
      lines: lines, references: references, shouldCancel: shouldCancel)
    return HarnessMarkdownDocument(blocks: parser.parseBlocks())
  }
}

private struct HarnessMarkdownBlockParser {
  private let lines: [String]
  private let references: [String: HarnessMarkdownReference]
  private let shouldCancel: @Sendable () -> Bool
  private var index = 0

  init(
    lines: [String],
    references: [String: HarnessMarkdownReference],
    shouldCancel: @escaping @Sendable () -> Bool
  ) {
    self.lines = lines
    self.references = references
    self.shouldCancel = shouldCancel
  }

  mutating func parseBlocks() -> [HarnessMarkdownBlock] {
    var blocks: [HarnessMarkdownBlock] = []
    while index < lines.count {
      guard !shouldCancel() else { return blocks }
      let line = lines[index]
      if let block = parseNextBlock(line) { blocks.append(block) }
    }
    return blocks
  }

  private mutating func parseNextBlock(_ line: String) -> HarnessMarkdownBlock? {
    if skipIgnorableLine(line) { return nil }
    if let block = parseCodeOrDetailsBlock(line) { return block }
    if let block = parseInlineStructuredBlock(line) { return block }
    if let block = parseContainerBlock(line) { return block }
    if isHTML(line) { return parseHTMLBlock() }
    if let setext = setextHeading(at: index) {
      index += 2
      return setext
    }
    return parseParagraph()
  }

  private mutating func skipIgnorableLine(_ line: String) -> Bool {
    if line.isBlank {
      index += 1
      return true
    }
    if HarnessMarkdownHTMLBlocks.isStandaloneCommentStart(line) {
      skipHTMLComment()
      return true
    }
    if HarnessMarkdownReferenceDefinitions.definition(line) != nil {
      index += 1
      return true
    }
    return false
  }

  private mutating func parseCodeOrDetailsBlock(_ line: String) -> HarnessMarkdownBlock? {
    if let fence = fenceStart(line) { return parseFencedCode(fence) }
    if HarnessMarkdownHTMLBlocks.detailsStart(line) != nil { return parseDetails() }
    if line.leadingSpaceCount >= 4 { return parseIndentedCode() }
    return nil
  }

  private mutating func parseInlineStructuredBlock(_ line: String) -> HarnessMarkdownBlock? {
    if let heading = heading(line, references: references) {
      index += 1
      return heading
    }
    if isThematicBreak(line) {
      index += 1
      return .thematicBreak
    }
    return nil
  }

  private mutating func parseContainerBlock(_ line: String) -> HarnessMarkdownBlock? {
    if line.trimmingLeadingSpaces().hasPrefix(">") { return parseBlockQuote() }
    if unorderedMarker(line) != nil { return parseUnorderedList() }
    if orderedMarker(line) != nil { return parseOrderedList() }
    if isTableStart(at: index) { return parseTable() }
    return nil
  }

  private mutating func parseFencedCode(_ fence: FenceStart) -> HarnessMarkdownBlock {
    index += 1
    var body: [String] = []
    while index < lines.count {
      guard !shouldCancel() else { return .codeBlock(language: .generic, source: "", tokens: []) }
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
      guard !shouldCancel() else { return .codeBlock(language: .generic, source: "", tokens: []) }
      body.append(lines[index].droppingLeadingSpaces(4))
      index += 1
    }
    let source = body.joined(separator: "\n")
    return .codeBlock(
      language: .generic,
      source: source,
      tokens: HarnessCodeHighlighter.highlight(source, language: .generic)
    )
  }

  private mutating func parseBlockQuote() -> HarnessMarkdownBlock {
    var quoteLines: [String] = []
    while index < lines.count {
      guard !shouldCancel() else { break }
      let trimmed = lines[index].trimmingLeadingSpaces()
      guard trimmed.hasPrefix(">") else { break }
      var content = String(trimmed.dropFirst())
      if content.hasPrefix(" ") { content.removeFirst() }
      quoteLines.append(content)
      index += 1
    }
    var parser = childParser(lines: quoteLines)
    return .blockQuote(parser.parseBlocks())
  }

  private mutating func parseUnorderedList() -> HarnessMarkdownBlock {
    var items: [HarnessMarkdownListItem] = []
    while index < lines.count, let marker = unorderedMarker(lines[index]) {
      guard !shouldCancel() else { break }
      index += 1
      items.append(parseListItem(firstLine: marker.content, checkbox: marker.checkbox))
    }
    return .unorderedList(items)
  }

  private mutating func parseOrderedList() -> HarnessMarkdownBlock {
    let start = orderedMarker(lines[index])?.number ?? 1
    var items: [HarnessMarkdownListItem] = []
    while index < lines.count, let marker = orderedMarker(lines[index]) {
      guard !shouldCancel() else { break }
      index += 1
      items.append(parseListItem(firstLine: marker.content, checkbox: nil))
    }
    return .orderedList(start: start, items: items)
  }

  private mutating func parseListItem(firstLine: String, checkbox: Bool?) -> HarnessMarkdownListItem
  {
    var itemLines = [firstLine]
    while index < lines.count {
      guard !shouldCancel() else { break }
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
    var parser = childParser(lines: itemLines)
    return HarnessMarkdownListItem(checkbox: checkbox, blocks: parser.parseBlocks())
  }

  private mutating func parseTable() -> HarnessMarkdownBlock {
    let headers = splitTableRow(lines[index]).map {
      HarnessMarkdownInlineParser.parse($0, references: references)
    }
    let alignments = tableAlignments(lines[index + 1])
    index += 2
    var rows: [[[HarnessMarkdownInline]]] = []
    while index < lines.count, lines[index].contains("|"), !lines[index].isBlank {
      guard !shouldCancel() else { break }
      rows.append(
        splitTableRow(lines[index]).map {
          HarnessMarkdownInlineParser.parse($0, references: references)
        })
      index += 1
    }
    return .table(HarnessMarkdownTable(headers: headers, alignments: alignments, rows: rows))
  }

  private mutating func parseHTMLBlock() -> HarnessMarkdownBlock? {
    var body: [String] = []
    while index < lines.count, !lines[index].isBlank {
      guard !shouldCancel() else { break }
      body.append(lines[index].trimmingLeadingSpaces())
      index += 1
      if body.count == 1, isSingleLineHTML(body[0]) { break }
    }
    let html = HarnessMarkdownHTMLBlocks.removingComments(from: body.joined(separator: "\n"))
    let inlines = HarnessMarkdownInlineParser.parse(html, references: references)
    return inlines.isEmpty ? nil : .html(inlines)
  }

  private mutating func parseDetails() -> HarnessMarkdownBlock {
    var body: [String] = []
    var depth = 0
    while index < lines.count {
      guard !shouldCancel() else { break }
      let line = lines[index]
      if HarnessMarkdownHTMLBlocks.detailsStart(line) != nil { depth += 1 }
      body.append(line)
      index += 1
      if HarnessMarkdownHTMLBlocks.containsDetailsClose(line) {
        depth -= 1
        if depth <= 0 { break }
      }
    }
    let details = HarnessMarkdownHTMLBlocks.details(from: body.joined(separator: "\n"))
    var parser = childParser(
      lines: details.body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    )
    return .details(
      HarnessMarkdownDetails(
        summary: HarnessMarkdownInlineParser.parse(details.summary, references: references),
        blocks: parser.parseBlocks(),
        isOpen: details.isOpen
      ))
  }

  private mutating func skipHTMLComment() {
    while index < lines.count {
      defer { index += 1 }
      if lines[index].contains("-->") { break }
    }
  }

  private mutating func parseParagraph() -> HarnessMarkdownBlock {
    var body: [String] = []
    while index < lines.count, !lines[index].isBlank, !startsBlock(lines[index], at: index) {
      guard !shouldCancel() else { break }
      body.append(lines[index].trimmingLeadingSpaces())
      index += 1
    }
    return .paragraph(
      HarnessMarkdownInlineParser.parse(body.joined(separator: "\n"), references: references))
  }

  private func startsBlock(_ line: String, at lineIndex: Int) -> Bool {
    fenceStart(line) != nil
      || line.leadingSpaceCount >= 4
      || heading(line, references: references) != nil
      || HarnessMarkdownHTMLBlocks.isStandaloneCommentStart(line)
      || HarnessMarkdownHTMLBlocks.detailsStart(line) != nil
      || isThematicBreak(line)
      || line.trimmingLeadingSpaces().hasPrefix(">")
      || unorderedMarker(line) != nil
      || orderedMarker(line) != nil
      || isTableStart(at: lineIndex)
      || setextHeading(at: lineIndex) != nil
      || HarnessMarkdownReferenceDefinitions.definition(line) != nil
      || isHTML(line)
  }

  private func isTableStart(at lineIndex: Int) -> Bool {
    lineIndex + 1 < lines.count
      && lines[lineIndex].contains("|")
      && isTableSeparator(lines[lineIndex + 1])
  }

  private func setextHeading(at lineIndex: Int) -> HarnessMarkdownBlock? {
    guard lineIndex + 1 < lines.count, !lines[lineIndex].isBlank else { return nil }
    let underline = lines[lineIndex + 1].filter { !$0.isWhitespace }
    guard underline.count >= 1, let marker = underline.first else { return nil }
    guard marker == "=" || marker == "-", underline.allSatisfy({ $0 == marker }) else { return nil }
    let text = lines[lineIndex].trimmingCharacters(in: .whitespaces)
    return .heading(
      level: marker == "=" ? 1 : 2,
      inlines: HarnessMarkdownInlineParser.parse(text, references: references)
    )
  }

  private func childParser(lines: [String]) -> Self {
    Self(lines: lines, references: references, shouldCancel: shouldCancel)
  }
}

extension String {
  var isBlank: Bool {
    allSatisfy(\.isWhitespace)
  }

  var leadingSpaceCount: Int {
    prefix { $0 == " " }.count
  }

  func trimmingLeadingSpaces() -> String {
    String(drop { $0 == " " || $0 == "\t" })
  }

  func droppingLeadingSpaces(_ count: Int) -> String {
    var dropped = 0
    var cursor = startIndex
    while cursor < endIndex, dropped < count, self[cursor] == " " {
      cursor = index(after: cursor)
      dropped += 1
    }
    return String(self[cursor...])
  }
}
