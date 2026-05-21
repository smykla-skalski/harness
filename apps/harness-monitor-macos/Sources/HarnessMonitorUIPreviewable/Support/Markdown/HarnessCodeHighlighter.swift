import SwiftUI

enum HarnessCodeHighlighter {
  private static let swiftKeywords: Set<String> = [
    "actor", "as", "async", "await", "case", "catch", "class", "enum", "extension", "for",
    "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "public",
    "return", "self", "static", "struct", "switch", "throw", "try", "var", "while",
  ]
  private static let rustKeywords: Set<String> = [
    "async", "await", "const", "crate", "enum", "false", "fn", "for", "if", "impl", "let",
    "match", "mod", "mut", "pub", "return", "self", "struct", "true", "use", "where",
  ]
  private static let shellKeywords: Set<String> = [
    "case", "cd", "done", "do", "elif", "else", "esac", "export", "fi", "for", "function",
    "if", "in", "local", "then", "while",
  ]
  private static let literals: Set<String> = ["false", "nil", "null", "true"]
  private static let punctuation: Set<Character> = ["(", ")", "[", "]", "{", "}", ",", ".", ":"]
  private static let operators: Set<Character> = [
    "=", "+", "-", "*", "/", "%", "!", "<", ">", "&", "|", "^", "~", "?",
  ]

  static func highlight(_ source: String, language: HarnessCodeLanguage) -> [HarnessCodeToken] {
    switch language {
    case .diff:
      highlightDiff(source)
    case .generic:
      [.init(text: source, kind: .plain)]
    case .json:
      highlightJSON(source)
    case .markdown:
      highlightMarkdown(source)
    case .rust:
      highlightCode(source, keywords: rustKeywords, lineComment: "//", blockComment: true)
    case .shell:
      highlightShell(source)
    case .swift:
      highlightCode(source, keywords: swiftKeywords, lineComment: "//", blockComment: true)
    case .yaml:
      highlightYAML(source)
    }
  }

  static func makeAttributedString(
    from tokens: [HarnessCodeToken],
    colors: HarnessCodeTokenColors = .default
  ) -> AttributedString {
    tokens.reduce(into: AttributedString()) { result, token in
      var fragment = AttributedString(token.text)
      fragment.foregroundColor = colors.color(for: token.kind)
      result += fragment
    }
  }

  private static func highlightCode(
    _ source: String,
    keywords: Set<String>,
    lineComment: String,
    blockComment: Bool
  ) -> [HarnessCodeToken] {
    let characters = Array(source)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < characters.count {
      if starts(lineComment, in: characters, at: index) {
        appendUntilNewline(in: characters, from: &index, kind: .comment, to: &tokens)
      } else if blockComment, starts("/*", in: characters, at: index) {
        appendBlockComment(in: characters, from: &index, to: &tokens)
      } else if characters[index] == "\"" {
        appendQuoted(in: characters, from: &index, to: &tokens)
      } else if characters[index].isWhitespace {
        appendRun(
          in: characters, from: &index, while: \.isWhitespace, kind: .whitespace, to: &tokens)
      } else if punctuation.contains(characters[index]) {
        tokens.append(.init(text: String(characters[index]), kind: .punctuation))
        index += 1
      } else if operators.contains(characters[index]) {
        tokens.append(.init(text: String(characters[index]), kind: .operatorSymbol))
        index += 1
      } else if characters[index].isNumber {
        appendRun(
          in: characters, from: &index, while: { $0.isNumber || $0 == "." }, kind: .number,
          to: &tokens)
      } else if isIdentifierStart(characters[index]) {
        appendIdentifier(in: characters, from: &index, keywords: keywords, to: &tokens)
      } else {
        tokens.append(.init(text: String(characters[index]), kind: .plain))
        index += 1
      }
    }
    return tokens
  }

  private static func highlightShell(_ source: String) -> [HarnessCodeToken] {
    let characters = Array(source)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < characters.count {
      if characters[index] == "#" {
        appendUntilNewline(in: characters, from: &index, kind: .comment, to: &tokens)
      } else if characters[index] == "\"" || characters[index] == "'" {
        appendQuoted(in: characters, from: &index, to: &tokens)
      } else if characters[index] == "$" {
        appendRun(
          in: characters, from: &index, while: { isIdentifierPart($0) || $0 == "$" },
          kind: .literal, to: &tokens)
      } else if characters[index].isWhitespace {
        appendRun(
          in: characters, from: &index, while: \.isWhitespace, kind: .whitespace, to: &tokens)
      } else if isIdentifierStart(characters[index]) {
        appendIdentifier(in: characters, from: &index, keywords: shellKeywords, to: &tokens)
      } else {
        let kind: HarnessCodeToken.Kind =
          operators.contains(characters[index]) ? .operatorSymbol : .plain
        tokens.append(.init(text: String(characters[index]), kind: kind))
        index += 1
      }
    }
    return tokens
  }

  private static func highlightJSON(_ source: String) -> [HarnessCodeToken] {
    let characters = Array(source)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < characters.count {
      let character = characters[index]
      if character.isWhitespace {
        appendRun(
          in: characters, from: &index, while: \.isWhitespace, kind: .whitespace, to: &tokens)
      } else if ["{", "}", "[", "]", ":", ","].contains(character) {
        tokens.append(.init(text: String(character), kind: .punctuation))
        index += 1
      } else if character == "\"" {
        let end = quotedEnd(in: characters, start: index)
        let kind: HarnessCodeToken.Kind =
          nextNonWhitespace(in: characters, after: end) == ":" ? .property : .string
        tokens.append(.init(text: String(characters[index...end]), kind: kind))
        index = end + 1
      } else {
        appendLiteral(in: characters, from: &index, to: &tokens)
      }
    }
    return tokens
  }

  private static func highlightYAML(_ source: String) -> [HarnessCodeToken] {
    source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap {
      offset, line in
      var tokens: [HarnessCodeToken] = offset == 0 ? [] : [.init(text: "\n", kind: .whitespace)]
      tokens.append(contentsOf: highlightYAMLLine(String(line)))
      return tokens
    }
  }

  private static func highlightYAMLLine(_ line: String) -> [HarnessCodeToken] {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("#") { return [.init(text: line, kind: .comment)] }
    guard let colon = firstUnquotedColon(in: Array(line)) else {
      return [.init(text: line, kind: .plain)]
    }
    let chars = Array(line)
    var tokens: [HarnessCodeToken] = [
      .init(text: String(chars[..<colon]), kind: .property),
      .init(text: ":", kind: .punctuation),
    ]
    if colon + 1 < chars.count {
      let value = String(chars[(colon + 1)...])
      let kind: HarnessCodeToken.Kind =
        literals.contains(value.trimmingCharacters(in: .whitespaces)) ? .literal : .plain
      tokens.append(.init(text: value, kind: kind))
    }
    return tokens
  }

  private static func highlightDiff(_ source: String) -> [HarnessCodeToken] {
    source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map {
      offset, line in
      let prefix = offset == 0 ? "" : "\n"
      let text = String(line)
      let kind: HarnessCodeToken.Kind =
        text.hasPrefix("@@")
        ? .heading : text.hasPrefix("+") ? .inserted : text.hasPrefix("-") ? .deleted : .plain
      return .init(text: prefix + text, kind: kind)
    }
  }

  private static func highlightMarkdown(_ source: String) -> [HarnessCodeToken] {
    source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap {
      offset, line in
      var tokens: [HarnessCodeToken] = offset == 0 ? [] : [.init(text: "\n", kind: .whitespace)]
      let text = String(line)
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      let kind: HarnessCodeToken.Kind = trimmed.hasPrefix("#") ? .heading : .plain
      tokens.append(.init(text: text, kind: kind))
      return tokens
    }
  }

  private static func appendRun(
    in chars: [Character],
    from index: inout Int,
    while predicate: (Character) -> Bool,
    kind: HarnessCodeToken.Kind,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    while index < chars.count, predicate(chars[index]) { index += 1 }
    tokens.append(.init(text: String(chars[start..<index]), kind: kind))
  }

  private static func appendUntilNewline(
    in chars: [Character],
    from index: inout Int,
    kind: HarnessCodeToken.Kind,
    to tokens: inout [HarnessCodeToken]
  ) {
    appendRun(in: chars, from: &index, while: { $0 != "\n" }, kind: kind, to: &tokens)
  }

  private static func appendBlockComment(
    in chars: [Character],
    from index: inout Int,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    index += 2
    while index + 1 < chars.count, !(chars[index] == "*" && chars[index + 1] == "/") {
      index += 1
    }
    index = min(index + 2, chars.count)
    tokens.append(.init(text: String(chars[start..<index]), kind: .comment))
  }

  private static func appendQuoted(
    in chars: [Character], from index: inout Int, to tokens: inout [HarnessCodeToken]
  ) {
    let end = quotedEnd(in: chars, start: index)
    tokens.append(.init(text: String(chars[index...end]), kind: .string))
    index = end + 1
  }

  private static func appendIdentifier(
    in chars: [Character],
    from index: inout Int,
    keywords: Set<String>,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    index += 1
    while index < chars.count, isIdentifierPart(chars[index]) { index += 1 }
    let text = String(chars[start..<index])
    let kind: HarnessCodeToken.Kind =
      keywords.contains(text)
      ? .keyword
      : literals.contains(text) ? .literal : text.first?.isUppercase == true ? .type : .plain
    tokens.append(.init(text: text, kind: kind))
  }

  private static func appendLiteral(
    in chars: [Character], from index: inout Int, to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    while index < chars.count, !chars[index].isWhitespace,
      !["{", "}", "[", "]", ":", ","].contains(chars[index])
    {
      index += 1
    }
    let text = String(chars[start..<index])
    let kind: HarnessCodeToken.Kind = literals.contains(text) ? .literal : .number
    tokens.append(.init(text: text, kind: kind))
  }

  private static func quotedEnd(in chars: [Character], start: Int) -> Int {
    let quote = chars[start]
    var index = start + 1
    var escaped = false
    while index < chars.count {
      if chars[index] == quote, !escaped { return index }
      escaped = chars[index] == "\\" && !escaped
      if chars[index] != "\\" { escaped = false }
      index += 1
    }
    return max(start, chars.count - 1)
  }

  private static func starts(_ needle: String, in chars: [Character], at index: Int) -> Bool {
    let needleChars = Array(needle)
    guard index + needleChars.count <= chars.count else { return false }
    return Array(chars[index..<(index + needleChars.count)]) == needleChars
  }

  private static func nextNonWhitespace(in chars: [Character], after index: Int) -> Character? {
    var candidate = index + 1
    while candidate < chars.count {
      if !chars[candidate].isWhitespace { return chars[candidate] }
      candidate += 1
    }
    return nil
  }

  private static func firstUnquotedColon(in chars: [Character]) -> Int? {
    var quote: Character?
    for (index, character) in chars.enumerated() {
      if character == "\"" || character == "'" {
        quote = quote == nil ? character : nil
      } else if character == ":", quote == nil {
        return index
      }
    }
    return nil
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character.isLetter || character == "_"
  }

  private static func isIdentifierPart(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }
}
