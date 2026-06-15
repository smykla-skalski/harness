import Foundation

struct HarnessMarkdownInlineParseState {
  let characters: [Character]
  let references: [String: HarnessMarkdownReference]
  var index = 0
  var buffer = ""
  var parts: [HarnessMarkdownInline] = []

  init(source: String, references: [String: HarnessMarkdownReference]) {
    self.characters = Array(source)
    self.references = references
  }

  mutating func flushBuffer() {
    guard !buffer.isEmpty else { return }
    parts.append(.text(HarnessMarkdownEmojiAliases.replacingAliases(in: buffer)))
    buffer.removeAll(keepingCapacity: true)
  }
}

enum HarnessMarkdownInlineParser {
  private static let escapable = Set("\\`*_{}[]()#+-.!|~<>")

  static func parse(
    _ source: String,
    references: [String: HarnessMarkdownReference] = [:]
  ) -> [HarnessMarkdownInline] {
    var state = HarnessMarkdownInlineParseState(source: source, references: references)

    while state.index < state.characters.count {
      consumeNext(from: &state)
    }

    state.flushBuffer()
    return state.parts
  }

  private static func consumeNext(from state: inout HarnessMarkdownInlineParseState) {
    if appendEscapeBreakOrCode(from: &state) { return }
    if appendDelimitedMarkup(from: &state) { return }
    if appendImageLinkOrHTML(from: &state) { return }
    if startsURL(in: state.characters, at: state.index) {
      appendBareAutolink(from: &state)
      return
    }
    state.buffer.append(state.characters[state.index])
    state.index += 1
  }

  private static func appendEscapeBreakOrCode(
    from state: inout HarnessMarkdownInlineParseState
  ) -> Bool {
    switch state.characters[state.index] {
    case "\\":
      appendEscaped(from: &state)
    case "\n":
      appendBreak(from: &state)
      state.index += 1
    case "`":
      appendCode(from: &state)
    default:
      return false
    }
    return true
  }

  private static func appendDelimitedMarkup(
    from state: inout HarnessMarkdownInlineParseState
  ) -> Bool {
    if starts("~~", in: state.characters, at: state.index) {
      appendDelimited("~~", .strikethrough, from: &state)
      return true
    }
    if starts("**", in: state.characters, at: state.index)
      || starts("__", in: state.characters, at: state.index)
    {
      let delimiter = String(state.characters[state.index...(state.index + 1)])
      appendDelimited(delimiter, .strong, from: &state)
      return true
    }
    if state.characters[state.index] == "*" || state.characters[state.index] == "_" {
      appendDelimited(String(state.characters[state.index]), .emphasis, from: &state)
      return true
    }
    return false
  }

  private static func appendImageLinkOrHTML(
    from state: inout HarnessMarkdownInlineParseState
  ) -> Bool {
    if isImageStart(in: state.characters, at: state.index) {
      if !HarnessMarkdownInlineImageScanner.appendImage(in: &state) {
        state.buffer.append(state.characters[state.index])
        state.index += 1
      }
      return true
    }
    if state.characters[state.index] == "[" {
      appendLink(from: &state)
      return true
    }
    if state.characters[state.index] == "<" {
      if !HarnessMarkdownHTMLInlineScanner.appendIfHTML(
        in: state.characters,
        from: &state.index,
        buffer: &state.buffer,
        into: &state.parts,
        references: state.references
      ) {
        appendAngleAutolink(from: &state)
      }
      return true
    }
    return false
  }

  private static func appendEscaped(from state: inout HarnessMarkdownInlineParseState) {
    guard state.index + 1 < state.characters.count else {
      state.buffer.append("\\")
      state.index += 1
      return
    }
    if state.characters[state.index + 1] == "\n" {
      state.flushBuffer()
      state.parts.append(.lineBreak)
      state.index += 2
    } else if escapable.contains(state.characters[state.index + 1]) {
      state.buffer.append(state.characters[state.index + 1])
      state.index += 2
    } else {
      state.buffer.append("\\")
      state.index += 1
    }
  }

  private static func appendBreak(from state: inout HarnessMarkdownInlineParseState) {
    if state.buffer.hasSuffix("  ") {
      state.buffer.removeLast(2)
      state.flushBuffer()
      state.parts.append(.lineBreak)
    } else {
      state.flushBuffer()
      state.parts.append(.softBreak)
    }
  }

  private static func appendCode(from state: inout HarnessMarkdownInlineParseState) {
    let run = delimiterRunLength("`", in: state.characters, at: state.index)
    let delimiter = String(repeating: "`", count: run)
    guard let end = findDelimiter(delimiter, in: state.characters, after: state.index + run) else {
      state.buffer.append(state.characters[state.index])
      state.index += 1
      return
    }
    state.flushBuffer()
    let raw = String(state.characters[(state.index + run)..<end])
      .replacingOccurrences(of: "\n", with: " ")
    state.parts.append(.code(raw))
    state.index = end + run
  }

  private static func appendDelimited(
    _ delimiter: String,
    _ kind: InlineDelimiterKind,
    from state: inout HarnessMarkdownInlineParseState
  ) {
    let start = state.index + delimiter.count
    guard let end = findDelimiter(delimiter, in: state.characters, after: start), end > start else {
      state.buffer.append(state.characters[state.index])
      state.index += 1
      return
    }
    state.flushBuffer()
    let nested = parse(String(state.characters[start..<end]), references: state.references)
    switch kind {
    case .emphasis:
      state.parts.append(.emphasis(nested))
    case .strong:
      state.parts.append(.strong(nested))
    case .strikethrough:
      state.parts.append(.strikethrough(nested))
    }
    state.index = end + delimiter.count
  }

  private static func appendLink(from state: inout HarnessMarkdownInlineParseState) {
    guard let labelEnd = matchingBracket(in: state.characters, at: state.index) else {
      state.buffer.append("[")
      state.index += 1
      return
    }
    let label = String(state.characters[(state.index + 1)..<labelEnd])
    if appendInlineLink(label: label, labelEnd: labelEnd, from: &state) { return }
    state.buffer.append("[")
    state.index += 1
  }

  private static func appendInlineLink(
    label: String,
    labelEnd: Int,
    from state: inout HarnessMarkdownInlineParseState
  ) -> Bool {
    if labelEnd + 1 < state.characters.count, state.characters[labelEnd + 1] == "(",
      let destination = linkDestination(in: state.characters, afterOpeningParen: labelEnd + 1)
    {
      state.flushBuffer()
      let parsed = destinationAndTitle(destination.raw)
      state.parts.append(
        .link(
          label: parse(label, references: state.references),
          destination: parsed.destination,
          title: parsed.title
        )
      )
      state.index = destination.end + 1
      return true
    }
    let reference = referenceLabel(after: labelEnd, label: label, in: state.characters)
    guard let target = state.references[normalizedReference(reference.label)] else { return false }
    state.flushBuffer()
    state.parts.append(
      .link(
        label: parse(label, references: state.references),
        destination: target.destination,
        title: target.title
      )
    )
    state.index = reference.end
    return true
  }

  private static func appendAngleAutolink(from state: inout HarnessMarkdownInlineParseState) {
    guard let end = first(">", in: state.characters, after: state.index + 1) else {
      state.buffer.append("<")
      state.index += 1
      return
    }
    let value = String(state.characters[(state.index + 1)..<end])
    guard value.hasPrefix("http://") || value.hasPrefix("https://") || value.contains("@") else {
      state.buffer.append("<")
      state.index += 1
      return
    }
    state.flushBuffer()
    state.parts.append(.autolink(value))
    state.index = end + 1
  }

  private static func appendBareAutolink(from state: inout HarnessMarkdownInlineParseState) {
    let start = state.index
    while state.index < state.characters.count, !state.characters[state.index].isWhitespace,
      !["<", ">", ")"].contains(state.characters[state.index])
    {
      state.index += 1
    }
    state.flushBuffer()
    var value = String(state.characters[start..<state.index])
    var trailing = ""
    while let last = value.last, ".,;:!?".contains(last) {
      trailing.insert(value.removeLast(), at: trailing.startIndex)
    }
    state.parts.append(.autolink(value))
    state.buffer.append(trailing)
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

  private static func isImageStart(in characters: [Character], at index: Int) -> Bool {
    index + 1 < characters.count && characters[index] == "!" && characters[index + 1] == "["
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
