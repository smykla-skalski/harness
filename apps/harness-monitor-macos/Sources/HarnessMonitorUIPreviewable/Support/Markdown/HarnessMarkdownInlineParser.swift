import Foundation

enum HarnessMarkdownInlineParser {
  private static let escapable = Set("\\`*_{}[]()#+-.!|~<>")

  static func parse(
    _ source: String,
    references: [String: HarnessMarkdownReference] = [:]
  ) -> [HarnessMarkdownInline] {
    var parts: [HarnessMarkdownInline] = []
    var buffer = ""
    let characters = Array(source)
    var index = 0

    while index < characters.count {
      if characters[index] == "\\" {
        appendEscaped(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if characters[index] == "\n" {
        appendBreak(from: &buffer, into: &parts)
        index += 1
      } else if characters[index] == "`" {
        appendCode(in: characters, from: &index, buffer: &buffer, into: &parts)
      } else if starts("~~", in: characters, at: index) {
        appendDelimited(
          "~~", .strikethrough, in: characters, from: &index, buffer: &buffer, into: &parts,
          references: references)
      } else if starts("**", in: characters, at: index) || starts("__", in: characters, at: index) {
        let delimiter = String(characters[index...(index + 1)])
        appendDelimited(
          delimiter, .strong, in: characters, from: &index, buffer: &buffer, into: &parts,
          references: references)
      } else if characters[index] == "*" || characters[index] == "_" {
        appendDelimited(
          String(characters[index]), .emphasis, in: characters, from: &index, buffer: &buffer,
          into: &parts, references: references)
      } else if characters[index] == "[" {
        appendLink(
          in: characters, from: &index, buffer: &buffer, into: &parts, references: references)
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
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    guard index + 1 < characters.count else {
      buffer.append("\\")
      index += 1
      return
    }
    if characters[index + 1] == "\n" {
      flush(&buffer, into: &parts)
      parts.append(.lineBreak)
      index += 2
    } else if escapable.contains(characters[index + 1]) {
      buffer.append(characters[index + 1])
      index += 2
    } else {
      buffer.append("\\")
      index += 1
    }
  }

  private static func appendBreak(
    from buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    if buffer.hasSuffix("  ") {
      buffer.removeLast(2)
      flush(&buffer, into: &parts)
      parts.append(.lineBreak)
    } else {
      flush(&buffer, into: &parts)
      parts.append(.softBreak)
    }
  }

  private static func appendCode(
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline]
  ) {
    let run = delimiterRunLength("`", in: characters, at: index)
    let delimiter = String(repeating: "`", count: run)
    guard let end = findDelimiter(delimiter, in: characters, after: index + run) else {
      buffer.append(characters[index])
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    let raw = String(characters[(index + run)..<end]).replacingOccurrences(of: "\n", with: " ")
    parts.append(.code(raw))
    index = end + run
  }

  private static func appendDelimited(
    _ delimiter: String,
    _ kind: InlineDelimiterKind,
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) {
    let start = index + delimiter.count
    guard let end = findDelimiter(delimiter, in: characters, after: start), end > start else {
      buffer.append(characters[index])
      index += 1
      return
    }
    flush(&buffer, into: &parts)
    let nested = parse(String(characters[start..<end]), references: references)
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
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) {
    guard let labelEnd = matchingBracket(in: characters, at: index) else {
      buffer.append("[")
      index += 1
      return
    }
    let label = String(characters[(index + 1)..<labelEnd])
    if appendInlineLink(
      label: label, labelEnd: labelEnd, in: characters, from: &index, buffer: &buffer, into: &parts,
      references: references)
    {
      return
    }
    buffer.append("[")
    index += 1
  }

  private static func appendInlineLink(
    label: String,
    labelEnd: Int,
    in characters: [Character],
    from index: inout Int,
    buffer: inout String,
    into parts: inout [HarnessMarkdownInline],
    references: [String: HarnessMarkdownReference]
  ) -> Bool {
    if labelEnd + 1 < characters.count, characters[labelEnd + 1] == "(",
      let destination = linkDestination(in: characters, afterOpeningParen: labelEnd + 1)
    {
      flush(&buffer, into: &parts)
      let parsed = destinationAndTitle(destination.raw)
      parts.append(
        .link(
          label: parse(label, references: references), destination: parsed.destination,
          title: parsed.title))
      index = destination.end + 1
      return true
    }
    let reference = referenceLabel(after: labelEnd, label: label, in: characters)
    guard let target = references[normalizedReference(reference.label)] else { return false }
    flush(&buffer, into: &parts)
    parts.append(
      .link(
        label: parse(label, references: references), destination: target.destination,
        title: target.title))
    index = reference.end
    return true
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
    while index < characters.count, !characters[index].isWhitespace,
      !["<", ">", ")"].contains(characters[index])
    {
      index += 1
    }
    flush(&buffer, into: &parts)
    var value = String(characters[start..<index])
    var trailing = ""
    while let last = value.last, ".,;:!?".contains(last) {
      trailing.insert(value.removeLast(), at: trailing.startIndex)
    }
    parts.append(.autolink(value))
    buffer.append(trailing)
  }

  private static func flush(_ buffer: inout String, into parts: inout [HarnessMarkdownInline]) {
    guard !buffer.isEmpty else { return }
    parts.append(.text(buffer))
    buffer.removeAll(keepingCapacity: true)
  }

  private static func matchingBracket(in characters: [Character], at start: Int) -> Int? {
    var index = start + 1
    var depth = 1
    while index < characters.count {
      if characters[index] == "\\" {
        index += 2
      } else if characters[index] == "[" {
        depth += 1
        index += 1
      } else if characters[index] == "]" {
        depth -= 1
        if depth == 0 { return index }
        index += 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func linkDestination(in characters: [Character], afterOpeningParen start: Int) -> (
    raw: String, end: Int
  )? {
    var index = start + 1
    var depth = 0
    var quote: Character?
    while index < characters.count {
      let character = characters[index]
      if character == "\\" {
        index += 2
      } else if character == "\"" || character == "'" {
        quote = quote == nil ? character : (quote == character ? nil : quote)
        index += 1
      } else if character == "(", quote == nil {
        depth += 1
        index += 1
      } else if character == ")", quote == nil {
        if depth == 0 {
          return (String(characters[(start + 1)..<index]), index)
        }
        depth -= 1
        index += 1
      } else {
        index += 1
      }
    }
    return nil
  }

  private static func destinationAndTitle(_ raw: String) -> (destination: String, title: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("<"), let close = trimmed.firstIndex(of: ">") {
      let destination = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
      return (destination, parsedTitle(String(trimmed[trimmed.index(after: close)...])))
    }
    guard let split = trimmed.firstIndex(where: \.isWhitespace) else {
      return (trimmed, nil)
    }
    return (String(trimmed[..<split]), parsedTitle(String(trimmed[split...])))
  }

  private static func parsedTitle(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, let first = trimmed.first, let last = trimmed.last else { return nil }
    if (first == "\"" && last == "\"") || (first == "'" && last == "'")
      || (first == "(" && last == ")")
    {
      return String(trimmed.dropFirst().dropLast())
    }
    return nil
  }

  private static func referenceLabel(after labelEnd: Int, label: String, in characters: [Character])
    -> (label: String, end: Int)
  {
    guard labelEnd + 1 < characters.count, characters[labelEnd + 1] == "[" else {
      return (label, labelEnd + 1)
    }
    guard let referenceEnd = first("]", in: characters, after: labelEnd + 2) else {
      return (label, labelEnd + 1)
    }
    let reference = String(characters[(labelEnd + 2)..<referenceEnd])
    return (reference.isEmpty ? label : reference, referenceEnd + 1)
  }

  private static func normalizedReference(_ label: String) -> String {
    label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func findDelimiter(
    _ delimiter: String, in characters: [Character], after start: Int
  ) -> Int? {
    var index = start
    while index < characters.count {
      if starts(delimiter, in: characters, at: index) { return index }
      index += 1
    }
    return nil
  }

  private static func first(_ character: Character, in characters: [Character], after start: Int)
    -> Int?
  {
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

  private static func delimiterRunLength(
    _ delimiter: Character, in characters: [Character], at index: Int
  ) -> Int {
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
