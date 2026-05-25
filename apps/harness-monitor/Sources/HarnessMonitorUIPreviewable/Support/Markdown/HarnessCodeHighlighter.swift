import SwiftUI

enum HarnessCodeHighlighter {
  private struct QuotedDelimiter {
    let opening: Character
    let closing: Character
    let supportsEscapes: Bool

    init(quote: Character, supportsEscapes: Bool) {
      opening = quote
      closing = quote
      self.supportsEscapes = supportsEscapes
    }
  }

  private enum VueRawSection: String {
    case script
    case style

    var closingTag: String { "</\(rawValue)" }
  }

  private static let swiftKeywords: Set<String> = [
    "actor", "as", "async", "await", "case", "catch", "class", "enum", "extension", "for",
    "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "public",
    "return", "self", "static", "struct", "switch", "throw", "try", "var", "while",
  ]
  private static let rustKeywords: Set<String> = [
    "async", "await", "const", "crate", "enum", "false", "fn", "for", "if", "impl", "let",
    "match", "mod", "mut", "pub", "return", "self", "struct", "true", "use", "where",
  ]
  private static let goKeywords: Set<String> = [
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
    "return", "select", "struct", "switch", "type", "var",
  ]
  private static let javascriptKeywords: Set<String> = [
    "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
    "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
    "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of",
    "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var",
    "void", "while", "yield",
  ]
  private static let typescriptKeywords: Set<String> = javascriptKeywords.union([
    "abstract", "any", "as", "asserts", "boolean", "declare", "enum", "implements", "infer",
    "interface", "is", "keyof", "module", "namespace", "never", "number", "object", "private",
    "protected", "public", "readonly", "satisfies", "string", "symbol", "type", "typeof",
    "undefined", "unique", "unknown",
  ])
  private static let featureSectionPrefixes = [
    "scenario outline:",
    "scenario template:",
    "background:",
    "examples:",
    "scenario:",
    "feature:",
    "example:",
    "rule:",
  ]
  private static let featureStepPrefixes = ["given", "when", "then", "and", "but"]
  private static let shellKeywords: Set<String> = [
    "case", "cd", "done", "do", "elif", "else", "esac", "export", "fi", "for", "function",
    "if", "in", "local", "then", "while",
  ]
  private static let defaultStringDelimiters = [QuotedDelimiter(quote: "\"", supportsEscapes: true)]
  private static let goStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
    QuotedDelimiter(quote: "`", supportsEscapes: false),
  ]
  // Template literals stay opaque on purpose; the lightweight tokenizer does
  // not attempt to parse nested `${...}` expressions inside them.
  private static let scriptStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
    QuotedDelimiter(quote: "`", supportsEscapes: true),
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
    case .feature:
      highlightFeature(source)
    case .generic:
      [.init(text: source, kind: .plain)]
    case .go:
      highlightCode(
        source,
        keywords: goKeywords,
        lineComment: "//",
        blockComment: true,
        stringDelimiters: goStringDelimiters
      )
    case .javascript:
      highlightCode(
        source,
        keywords: javascriptKeywords,
        lineComment: "//",
        blockComment: true,
        stringDelimiters: scriptStringDelimiters
      )
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
    case .typescript:
      highlightCode(
        source,
        keywords: typescriptKeywords,
        lineComment: "//",
        blockComment: true,
        stringDelimiters: scriptStringDelimiters
      )
    case .vue:
      highlightVue(source)
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
    blockComment: Bool,
    stringDelimiters: [QuotedDelimiter] = defaultStringDelimiters
  ) -> [HarnessCodeToken] {
    let characters = Array(source)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < characters.count {
      if starts(lineComment, in: characters, at: index) {
        appendUntilNewline(in: characters, from: &index, kind: .comment, to: &tokens)
      } else if blockComment, starts("/*", in: characters, at: index) {
        appendBlockComment(in: characters, from: &index, to: &tokens)
      } else if let delimiter = stringDelimiter(
        matching: characters[index],
        in: stringDelimiters
      ) {
        appendQuoted(in: characters, from: &index, delimiter: delimiter, to: &tokens)
      } else if characters[index].isWhitespace {
        appendRun(
          in: characters,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
      } else if punctuation.contains(characters[index]) {
        tokens.append(.init(text: String(characters[index]), kind: .punctuation))
        index += 1
      } else if operators.contains(characters[index]) {
        tokens.append(.init(text: String(characters[index]), kind: .operatorSymbol))
        index += 1
      } else if characters[index].isNumber {
        appendRun(
          in: characters,
          from: &index,
          while: { $0.isNumber || $0 == "." },
          kind: .number,
          to: &tokens
        )
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
          in: characters,
          from: &index,
          while: { isIdentifierPart($0) || $0 == "$" },
          kind: .literal,
          to: &tokens
        )
      } else if characters[index].isWhitespace {
        appendRun(
          in: characters,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
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
          in: characters,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
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
    let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
    return sourceLines.enumerated().flatMap { offset, line in
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
    let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
    return sourceLines.enumerated().map { offset, line in
      let prefix = offset == 0 ? "" : "\n"
      let text = String(line)
      let kind: HarnessCodeToken.Kind =
        text.hasPrefix("@@")
        ? .heading : text.hasPrefix("+") ? .inserted : text.hasPrefix("-") ? .deleted : .plain
      return .init(text: prefix + text, kind: kind)
    }
  }

  private static func highlightMarkdown(_ source: String) -> [HarnessCodeToken] {
    let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
    return sourceLines.enumerated().flatMap { offset, line in
      var tokens: [HarnessCodeToken] = offset == 0 ? [] : [.init(text: "\n", kind: .whitespace)]
      let text = String(line)
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      let kind: HarnessCodeToken.Kind = trimmed.hasPrefix("#") ? .heading : .plain
      tokens.append(.init(text: text, kind: kind))
      return tokens
    }
  }

  private static func highlightFeature(_ source: String) -> [HarnessCodeToken] {
    let sourceLines = source.split(separator: "\n", omittingEmptySubsequences: false)
    var inDocstring = false
    return sourceLines.enumerated().flatMap { offset, line in
      var tokens: [HarnessCodeToken] = offset == 0 ? [] : [.init(text: "\n", kind: .whitespace)]
      tokens.append(contentsOf: highlightFeatureLine(String(line), inDocstring: &inDocstring))
      return tokens
    }
  }

  private static func highlightFeatureLine(
    _ line: String,
    inDocstring: inout Bool
  ) -> [HarnessCodeToken] {
    var tokens: [HarnessCodeToken] = []
    let leadingWhitespace = String(line.prefix(while: \.isWhitespace))
    let trimmed = String(line.dropFirst(leadingWhitespace.count))
    if !leadingWhitespace.isEmpty {
      tokens.append(.init(text: leadingWhitespace, kind: .whitespace))
    }
    guard !trimmed.isEmpty else { return tokens }

    if isFeatureDocstringDelimiter(trimmed) {
      inDocstring.toggle()
      tokens.append(.init(text: trimmed, kind: .string))
      return tokens
    }

    if inDocstring {
      tokens.append(.init(text: trimmed, kind: .string))
      return tokens
    }

    let lowercased = trimmed.lowercased()
    if lowercased.hasPrefix("#") {
      tokens.append(.init(text: trimmed, kind: .comment))
      return tokens
    }

    if lowercased.hasPrefix("@") {
      tokens.append(contentsOf: highlightFeatureTags(trimmed))
      return tokens
    }

    if let prefix = featureSectionPrefixes.first(where: { lowercased.hasPrefix($0) }) {
      let boundary = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
      tokens.append(.init(text: String(trimmed[..<boundary]), kind: .heading))
      if boundary < trimmed.endIndex {
        tokens.append(.init(text: String(trimmed[boundary...]), kind: .plain))
      }
      return tokens
    }

    if let stepPrefix = featureStepPrefix(for: trimmed) {
      let boundary = trimmed.index(trimmed.startIndex, offsetBy: stepPrefix.count)
      tokens.append(.init(text: String(trimmed[..<boundary]), kind: .keyword))
      if boundary < trimmed.endIndex {
        tokens.append(.init(text: String(trimmed[boundary...]), kind: .plain))
      }
      return tokens
    }

    if trimmed.first == "|" {
      tokens.append(contentsOf: highlightFeatureTable(trimmed))
      return tokens
    }

    tokens.append(.init(text: trimmed, kind: .plain))
    return tokens
  }

  private static func highlightFeatureTags(_ line: String) -> [HarnessCodeToken] {
    let chars = Array(line)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < chars.count {
      if chars[index].isWhitespace {
        appendRun(
          in: chars,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
      } else if chars[index] == "#" {
        appendUntilNewline(in: chars, from: &index, kind: .comment, to: &tokens)
      } else if chars[index] == "@" {
        appendRun(
          in: chars,
          from: &index,
          while: { !$0.isWhitespace && $0 != "#" },
          kind: .property,
          to: &tokens
        )
      } else {
        appendRun(
          in: chars,
          from: &index,
          while: { !$0.isWhitespace && $0 != "#" },
          kind: .plain,
          to: &tokens
        )
      }
    }
    return tokens
  }

  private static func highlightFeatureTable(_ line: String) -> [HarnessCodeToken] {
    let chars = Array(line)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    while index < chars.count {
      if chars[index] == "|" {
        tokens.append(.init(text: "|", kind: .punctuation))
        index += 1
      } else if chars[index].isWhitespace {
        appendRun(
          in: chars,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
      } else {
        appendRun(
          in: chars,
          from: &index,
          while: { !$0.isWhitespace && $0 != "|" },
          kind: .plain,
          to: &tokens
        )
      }
    }
    return tokens
  }

  private static func highlightVue(_ source: String) -> [HarnessCodeToken] {
    let chars = Array(source)
    var index = 0
    var tokens: [HarnessCodeToken] = []
    var rawSection: VueRawSection?

    while index < chars.count {
      if let currentRawSection = rawSection {
        if startsCaseInsensitive(currentRawSection.closingTag, in: chars, at: index) {
          appendVueTag(in: chars, from: &index, to: &tokens, rawSection: &rawSection)
        } else {
          appendUntilCaseInsensitive(
            currentRawSection.closingTag,
            in: chars,
            from: &index,
            kind: .plain,
            to: &tokens
          )
        }
      } else if starts("<!--", in: chars, at: index) {
        appendThroughSequence("-->", in: chars, from: &index, kind: .comment, to: &tokens)
      } else if starts("{{", in: chars, at: index) {
        appendThroughSequence("}}", in: chars, from: &index, kind: .literal, to: &tokens)
      } else if chars[index] == "<" {
        appendVueTag(in: chars, from: &index, to: &tokens, rawSection: &rawSection)
      } else if chars[index].isWhitespace {
        appendRun(
          in: chars,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
      } else {
        appendVueText(in: chars, from: &index, to: &tokens)
      }
    }

    return tokens
  }

  private static func appendVueTag(
    in chars: [Character],
    from index: inout Int,
    to tokens: inout [HarnessCodeToken],
    rawSection: inout VueRawSection?
  ) {
    guard chars[index] == "<" else { return }
    tokens.append(.init(text: "<", kind: .punctuation))
    index += 1

    let isClosingTag = index < chars.count && chars[index] == "/"
    if isClosingTag {
      tokens.append(.init(text: "/", kind: .punctuation))
      index += 1
    }

    let tagStart = index
    while index < chars.count, isVueTagNameCharacter(chars[index]) { index += 1 }
    let tagName = String(chars[tagStart..<index])
    if !tagName.isEmpty {
      tokens.append(.init(text: tagName, kind: .type))
    }
    let lowercasedTag = tagName.lowercased()

    while index < chars.count {
      if starts("/>", in: chars, at: index) {
        tokens.append(.init(text: "/>", kind: .punctuation))
        index += 2
        return
      }
      if chars[index] == ">" {
        tokens.append(.init(text: ">", kind: .punctuation))
        index += 1
        if !isClosingTag {
          if lowercasedTag == VueRawSection.script.rawValue {
            rawSection = .script
          } else if lowercasedTag == VueRawSection.style.rawValue {
            rawSection = .style
          }
        } else if lowercasedTag == VueRawSection.script.rawValue
            || lowercasedTag == VueRawSection.style.rawValue {
          rawSection = nil
        }
        return
      }
      if chars[index].isWhitespace {
        appendRun(
          in: chars,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &tokens
        )
      } else if chars[index] == "\"" || chars[index] == "'" {
        appendQuoted(in: chars, from: &index, to: &tokens)
      } else if chars[index] == "=" {
        tokens.append(.init(text: "=", kind: .punctuation))
        index += 1
      } else {
        let attributeStart = index
        while index < chars.count, isVueAttributeCharacter(chars[index]) { index += 1 }
        if attributeStart == index {
          tokens.append(.init(text: String(chars[index]), kind: .plain))
          index += 1
        } else {
          tokens.append(.init(text: String(chars[attributeStart..<index]), kind: .property))
        }
      }
    }
  }

  private static func appendVueText(
    in chars: [Character],
    from index: inout Int,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    while index < chars.count,
      !chars[index].isWhitespace,
      chars[index] != "<",
      !starts("{{", in: chars, at: index),
      !starts("<!--", in: chars, at: index)
    {
      index += 1
    }
    tokens.append(.init(text: String(chars[start..<index]), kind: .plain))
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
    appendQuoted(
      in: chars,
      from: &index,
      delimiter: QuotedDelimiter(quote: chars[index], supportsEscapes: true),
      to: &tokens
    )
  }

  private static func appendQuoted(
    in chars: [Character],
    from index: inout Int,
    delimiter: QuotedDelimiter,
    to tokens: inout [HarnessCodeToken]
  ) {
    let end = quotedEnd(in: chars, start: index, delimiter: delimiter)
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

  private static func appendThroughSequence(
    _ needle: String,
    in chars: [Character],
    from index: inout Int,
    kind: HarnessCodeToken.Kind,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    while index < chars.count {
      if starts(needle, in: chars, at: index) {
        index += needle.count
        tokens.append(.init(text: String(chars[start..<index]), kind: kind))
        return
      }
      index += 1
    }
    tokens.append(.init(text: String(chars[start..<index]), kind: kind))
  }

  private static func appendUntilCaseInsensitive(
    _ needle: String,
    in chars: [Character],
    from index: inout Int,
    kind: HarnessCodeToken.Kind,
    to tokens: inout [HarnessCodeToken]
  ) {
    let start = index
    while index < chars.count, !startsCaseInsensitive(needle, in: chars, at: index) {
      index += 1
    }
    if start < index {
      tokens.append(.init(text: String(chars[start..<index]), kind: kind))
    }
  }

  private static func quotedEnd(in chars: [Character], start: Int) -> Int {
    quotedEnd(
      in: chars,
      start: start,
      delimiter: QuotedDelimiter(quote: chars[start], supportsEscapes: true)
    )
  }

  private static func quotedEnd(
    in chars: [Character],
    start: Int,
    delimiter: QuotedDelimiter
  ) -> Int {
    var index = start + 1
    var escaped = false
    while index < chars.count {
      if chars[index] == delimiter.closing, !escaped { return index }
      if delimiter.supportsEscapes {
        escaped = chars[index] == "\\" && !escaped
        if chars[index] != "\\" { escaped = false }
      }
      index += 1
    }
    return max(start, chars.count - 1)
  }

  private static func stringDelimiter(
    matching character: Character,
    in delimiters: [QuotedDelimiter]
  ) -> QuotedDelimiter? {
    delimiters.first { $0.opening == character }
  }

  private static func startsCaseInsensitive(
    _ needle: String,
    in chars: [Character],
    at index: Int
  ) -> Bool {
    let needleChars = Array(needle.lowercased())
    guard index + needleChars.count <= chars.count else { return false }
    for offset in needleChars.indices {
      if String(chars[index + offset]).lowercased() != String(needleChars[offset]) {
        return false
      }
    }
    return true
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

  private static func isFeatureDocstringDelimiter(_ line: String) -> Bool {
    line.hasPrefix("\"\"\"") || line.hasPrefix("```")
  }

  private static func featureStepPrefix(for line: String) -> String? {
    if line.hasPrefix("* ") || line == "*" {
      return "*"
    }
    let lowercased = line.lowercased()
    for prefix in featureStepPrefixes {
      if lowercased == prefix || lowercased.hasPrefix("\(prefix) ") {
        return String(line.prefix(prefix.count))
      }
    }
    return nil
  }

  private static func isVueTagNameCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_"
  }

  private static func isVueAttributeCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "-" || character == "_" || character == ":"
      || character == "@" || character == "." || character == "#" || character == "["
      || character == "]"
  }
}
