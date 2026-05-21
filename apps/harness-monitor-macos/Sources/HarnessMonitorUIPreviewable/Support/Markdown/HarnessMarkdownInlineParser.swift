import Foundation

enum HarnessMarkdownInlineParser {
  static func parse(_ source: String) -> [HarnessMarkdownInline] {
    var parts: [HarnessMarkdownInline] = []
    var buffer = ""
    let characters = Array(source)
    var index = 0

    while index < characters.count {
      if characters[index] == "\\" {
        appendEscaped(in: characters, from: &index, buffer: &buffer)
      } else if characters[index] == "\n" {
        flush(&buffer, into: &parts)
        parts.append(.lineBreak)
        index += 1
      } else if characters[index] == "`" {
        appendCode(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if starts("~~", in: characters, at: index) {
        appendDelimited("~~", .strikethrough, in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if starts("**", in: characters, at: index) {
        appendDelimited("**", .strong, in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if characters[index] == "*" || characters[index] == "_" {
        appendDelimited(String(characters[index]), .emphasis, in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if characters[index] == "[" {
        appendLink(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if characters[index] == "<" {
        appendAngleAutolink(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if startsURL(in: characters, at: index) {
        appendBareAutolink(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else {
        buffer.append(characters[index])
        index += 1
      }
    }

    flush(&buffer, into: &parts)
    return parts
  }

  private static func appendEscaped(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String
  ) {
    guard index + 1 < characters.count else {
      buffer.append("\\")
      index += 1
      return
    }
    buffer.append(characters[index + 1])
    index += 2
  }

  private static func appendCode(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    let run = delimiterRunLength("`", in: characters, at: index)
    guard let end = findDelimiter(String(repeating: "`", count: run), in: characters, after: index + run) else {
      buffer.append(characters[index])
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    parts.append(.code(String(characters[(index + run)..<end])))
    index = end + run
  }

  private static func appendDelimited(
    _ delimiter: String,
    _ kind: InlineDelimiterKind,
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    let start = index + delimiter.count
    guard let end = findDelimiter(delimiter, in: characters, after: start), end > start else {
      buffer.append(characters[index])
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    let nested = parse(String(characters[start..<end]))
    switch kind {
    case .emphasis:
      parts.append(.emphasis(nested))
    case .strong:
      parts.append(.strong(nested))
    case .strikethrough:
      parts.append(.strikethrough(nested))
    }
    index = end + delimiter.count
  }

  private static func appendLink(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    guard
      let labelEnd = first("]", in: characters, after: index + 1),
      labelEnd + 1 < characters.count,
      characters[labelEnd + 1] == "(",
      let destinationEnd = first(")", in: characters, after: labelEnd + 2)
    else {
      buffer.append("[")
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    let label = String(characters[(index + 1)..<labelEnd])
    let destination = String(characters[(labelEnd + 2)..<destinationEnd])
    parts.append(.link(label: parse(label), destination: destination))
    index = destinationEnd + 1
  }

  private static func appendAngleAutolink(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    guard let end = first(">", in: characters, after: index + 1) else {
      buffer.append("<")
      index += 1
      return
    }
    let value = String(characters[(index + 1)..<end])
    guard value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains("@") else {
      buffer.append("<")
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    parts.append(.autolink(value))
    index = end + 1
  }

  private static func appendBareAutolink(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    let start = index
    while index < characters.count, !characters[index].isWhitespace, !["<", ">", ")"].contains(characters[index]) {
      index += 1
    }
    flush(&buffer, into: &parts)
    parts.append(.autolink(String(characters[start..<index]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))))
  }

  private static func flush(_ buffer: inout String, into parts: inout [HarnessMarkdownInline]) {
    guard !buffer.isEmpty else { return }
    parts.append(.text(buffer))
    buffer.removeAll(keepingCapacity: true)
  }

  private static func findDelimiter(_ delimiter: String, in characters: [Character], after start: Int) -> Int? {
    var index = start
    while index < characters.count {
      if starts(delimiter, in: characters, at: index) { return index }
      index += 1
    }
    return nil
  }

  private static func first(_ character: Character, in characters: [Character], after start: Int) -> Int? {
    var index = start
    while index < characters.count {
      if characters[index] == character { return index }
      index += 1
    }
    return nil
  }

  private static func startsURL(in characters: [Character], at index: Int) -> Bool {
    starts("http://", in: characters, at: index) || starts("https://", in: characters, at: index)
  }

  private static func starts(_ needle: String, in characters: [Character], at index: Int) -> Bool {
    let needleCharacters = Array(needle)
    guard index + needleCharacters.count <= characters.count else { return false }
    return Array(characters[index..<(index + needleCharacters.count)]) == needleCharacters
  }

  private static func delimiterRunLength(_ delimiter: Character, in characters: [Character], at index: Int) -> Int {
    var candidate = index
    while candidate < characters.count, characters[candidate] == delimiter {
      candidate += 1
    }
    return candidate - index
  }
}

private enum InlineDelimiterKind {
  case emphasis
  case strong
  case strikethrough
}
