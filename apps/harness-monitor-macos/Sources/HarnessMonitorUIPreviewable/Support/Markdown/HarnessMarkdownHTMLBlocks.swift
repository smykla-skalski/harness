import Foundation

enum HarnessMarkdownHTMLBlocks {
  static func detailsStart(_ line: String) -> Bool? {
    let characters = Array(line.trimmingLeadingSpacesForHTML())
    guard let tag = HTMLInlineTag(characters: characters, start: 0), tag.name == "details",
      !tag.isClosing
    else { return nil }
    return tag.attributes.keys.contains("open")
  }

  static func containsDetailsClose(_ line: String) -> Bool {
    let characters = Array(line)
    var index = 0
    while index < characters.count {
      if let tag = HTMLInlineTag(characters: characters, start: index) {
        if tag.name == "details", tag.isClosing { return true }
        index = tag.end + 1
      } else {
        index += 1
      }
    }
    return false
  }

  static func isCommentStart(_ line: String) -> Bool {
    line.trimmingLeadingSpacesForHTML().hasPrefix("<!--")
  }

  static func details(from raw: String) -> (summary: String, body: String, isOpen: Bool) {
    let source = removingComments(from: raw)
    let characters = Array(source)
    guard let open = firstTag(named: "details", in: characters, closing: false, from: 0) else {
      return ("Details", source, false)
    }
    let isOpen = open.tag.attributes.keys.contains("open")
    let close = lastClosingTag(named: "details", in: characters) ?? characters.count
    let innerStart = open.tag.end + 1
    let innerEnd = max(innerStart, close)
    let inner = String(characters[innerStart..<innerEnd])
    guard let summary = summaryRange(in: Array(inner)) else {
      return ("Details", inner, isOpen)
    }
    let innerCharacters = Array(inner)
    let summaryText = String(innerCharacters[(summary.open.end + 1)..<summary.closeStart])
    let before = String(innerCharacters[..<summary.openStart])
    let after = String(innerCharacters[summary.closeEnd...])
    return (summaryText, [before, after].joined(separator: "\n"), isOpen)
  }

  static func removingComments(from source: String) -> String {
    let characters = Array(source)
    var result = ""
    var index = 0
    while index < characters.count {
      if starts("<!--", in: characters, at: index) {
        index = commentEnd(in: characters, after: index + 4).map { $0 + 3 } ?? characters.count
      } else {
        result.append(characters[index])
        index += 1
      }
    }
    return result
  }

  private static func summaryRange(in characters: [Character]) -> (
    openStart: Int, open: HTMLInlineTag, closeStart: Int, closeEnd: Int
  )? {
    guard let open = firstTag(named: "summary", in: characters, closing: false, from: 0),
      let close = firstTag(named: "summary", in: characters, closing: true, from: open.tag.end + 1)
    else { return nil }
    return (open.start, open.tag, close.start, close.tag.end + 1)
  }

  private static func firstTag(
    named name: String,
    in characters: [Character],
    closing: Bool,
    from start: Int
  ) -> (start: Int, tag: HTMLInlineTag)? {
    var index = start
    while index < characters.count {
      if let tag = HTMLInlineTag(characters: characters, start: index) {
        if tag.name == name, tag.isClosing == closing { return (index, tag) }
        index = tag.end + 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func lastClosingTag(named name: String, in characters: [Character]) -> Int? {
    var index = 0
    var result: Int?
    while index < characters.count {
      if let tag = HTMLInlineTag(characters: characters, start: index) {
        if tag.name == name, tag.isClosing { result = index }
        index = tag.end + 1
      } else {
        index += 1
      }
    }
    return result
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

  private static func starts(_ needle: String, in characters: [Character], at index: Int) -> Bool {
    let needleCharacters = Array(needle)
    guard index + needleCharacters.count <= characters.count else { return false }
    return Array(characters[index..<(index + needleCharacters.count)]) == needleCharacters
  }
}

extension String {
  fileprivate func trimmingLeadingSpacesForHTML() -> String {
    String(drop { $0 == " " || $0 == "\t" })
  }
}
