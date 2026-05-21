import Foundation

enum HarnessMarkdownHTMLInlineScanner {
  static func appendIfHTML(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) -> Bool {
    if starts("<!--", in: characters, at: index) {
      flush(&buffer, into: &parts)
      index = commentEnd(in: characters, after: index + 4).map { $0 + 3 } ?? characters.count
      return true
    }
    guard let tag = HTMLInlineTag(characters: characters, start: index) else { return false }
    guard !tag.name.isEmpty else { return false }
    if tag.isClosing {
      index = tag.end + 1
      return true
    }
    if tag.name == "br" {
      flush(&buffer, into: &parts)
      parts.append(.lineBreak)
      index = tag.end + 1
      return true
    }
    if tag.name == "img" {
      flush(&buffer, into: &parts)
      if let source = tag.attributes["src"], !source.isEmpty {
        parts.append(
          .image(
            HarnessMarkdownImage(
              source: source,
              alt: tag.attributes["alt"] ?? "",
              title: tag.attributes["title"]
            )))
      } else {
        appendText(tag.attributes["alt"] ?? "", into: &parts)
      }
      index = tag.end + 1
      return true
    }
    if ["script", "style"].contains(tag.name) {
      flush(&buffer, into: &parts)
      index =
        closingRange(named: tag.name, in: characters, after: tag.end + 1)?.after ?? characters.count
      return true
    }
    if let range = closingRange(named: tag.name, in: characters, after: tag.end + 1) {
      flush(&buffer, into: &parts)
      appendContent(
        String(characters[(tag.end + 1)..<range.open]),
        for: tag,
        into: &parts,
        references: references
      )
      index = range.after
      return true
    }
    guard
      tag.isSelfClosing || knownContainerTags.contains(tag.name) || textKind(for: tag.name) != nil
    else { return false }
    index = tag.end + 1
    return true
  }

  private static func appendContent(
    _ raw: String,
    for tag: HTMLInlineTag,
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) {
    let content = decodeEntities(HarnessMarkdownHTMLBlocks.removingComments(from: raw))
    switch textKind(for: tag.name) {
    case .strong:
      parts.append(.strong(HarnessMarkdownInlineParser.parse(content, references: references)))
    case .emphasis:
      parts.append(.emphasis(HarnessMarkdownInlineParser.parse(content, references: references)))
    case .strike:
      parts.append(
        .strikethrough(HarnessMarkdownInlineParser.parse(content, references: references)))
    case .code:
      parts.append(.code(content.replacingOccurrences(of: "\n", with: " ")))
    case .link:
      let label = HarnessMarkdownInlineParser.parse(content, references: references)
      if let href = tag.attributes["href"], !href.isEmpty {
        parts.append(.link(label: label, destination: href, title: tag.attributes["title"]))
      } else {
        parts.append(contentsOf: label)
      }
    case nil:
      parts.append(contentsOf: HarnessMarkdownInlineParser.parse(content, references: references))
    }
  }

  private static func appendText(_ text: String, into parts: inout [HarnessMarkdownInline]) {
    guard !text.isEmpty else { return }
    parts.append(.text(decodeEntities(text)))
  }

  private static func flush(_ buffer: inout String, into parts: inout [HarnessMarkdownInline]) {
    guard !buffer.isEmpty else { return }
    parts.append(.text(buffer))
    buffer.removeAll(keepingCapacity: true)
  }

  private static func closingRange(named name: String, in characters: [Character], after start: Int)
    -> (open: Int, after: Int)?
  {
    var index = start
    var depth = 1
    while index < characters.count {
      guard let tag = HTMLInlineTag(characters: characters, start: index) else {
        index += 1
        continue
      }
      if tag.name == name, !tag.isSelfClosing {
        if tag.isClosing {
          depth -= 1
          if depth == 0 { return (index, tag.end + 1) }
        } else {
          depth += 1
        }
      }
      index = tag.end + 1
    }
    return nil
  }

  private static func commentEnd(in characters: [Character], after start: Int) -> Int? {
    var index = start
    while index + 2 < characters.count {
      if characters[index] == "-", characters[index + 1] == "-", characters[index + 2] == ">" {
        return index
      }
      index += 1
    }
    return nil
  }

  private static func textKind(for name: String) -> HTMLTextKind? {
    switch name {
    case "b", "strong":
      .strong
    case "em", "i":
      .emphasis
    case "del", "s", "strike":
      .strike
    case "code", "kbd", "samp":
      .code
    case "a":
      .link
    default:
      nil
    }
  }

  private static let knownContainerTags: Set<String> = [
    "abbr", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt", "figcaption",
    "figure", "h1", "h2", "h3", "h4", "h5", "h6", "li", "ol", "p", "section", "span", "sub",
    "summary", "sup", "u", "ul",
  ]

  private static func starts(_ needle: String, in characters: [Character], at index: Int) -> Bool {
    let needleCharacters = Array(needle)
    guard index + needleCharacters.count <= characters.count else { return false }
    return Array(characters[index..<(index + needleCharacters.count)]) == needleCharacters
  }
}

private enum HTMLTextKind {
  case code
  case emphasis
  case link
  case strike
  case strong
}
