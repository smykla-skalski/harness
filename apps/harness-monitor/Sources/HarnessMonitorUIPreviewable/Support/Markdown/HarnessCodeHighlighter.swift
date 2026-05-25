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
  private static let dockerfileKeywords: Set<String> = [
    "add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck", "label",
    "onbuild", "run", "shell", "stopsignal", "user", "volume", "workdir",
    "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK", "LABEL",
    "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR",
  ]
  private static let goModuleKeywords: Set<String> = [
    "exclude", "go", "module", "replace", "require", "retract", "toolchain",
  ]
  private static let makefileKeywords: Set<String> = [
    "define", "else", "endef", "endif", "export", "ifdef", "ifndef", "ifeq", "ifneq", "include",
    "override", "private", "undefine", "unexport",
  ]
  private static let protoKeywords: Set<String> = [
    "enum", "extend", "extensions", "import", "message", "oneof", "option", "optional",
    "package", "repeated", "required", "returns", "rpc", "service", "syntax",
  ]
  private static let pythonKeywords: Set<String> = [
    "and", "as", "async", "await", "class", "def", "elif", "else", "except", "False", "for",
    "from", "if", "import", "in", "is", "lambda", "None", "not", "or", "pass", "raise",
    "return", "True", "try", "while", "with", "yield",
  ]
  private static let regoKeywords: Set<String> = [
    "contains", "default", "deny", "else", "every", "false", "if", "import", "in", "not",
    "null", "package", "some", "true", "with",
  ]
  private static let rubyKeywords: Set<String> = [
    "alias", "begin", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false",
    "if", "module", "nil", "require", "rescue", "return", "self", "super", "then", "true",
    "unless", "when", "while", "yield",
  ]
  private static let sqlKeywords: Set<String> = [
    "alter", "and", "as", "by", "create", "delete", "drop", "from", "group", "having",
    "insert", "into", "join", "limit", "not", "null", "on", "or", "order", "select", "set",
    "table", "union", "update", "values", "where",
    "ALTER", "AND", "AS", "BY", "CREATE", "DELETE", "DROP", "FROM", "GROUP", "HAVING",
    "INSERT", "INTO", "JOIN", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "SET",
    "TABLE", "UNION", "UPDATE", "VALUES", "WHERE",
  ]
  private static let stylesheetKeywords: Set<String> = [
    "charset", "container", "font-face", "forward", "import", "include", "keyframes", "media",
    "mixin", "namespace", "supports", "use",
  ]
  private static let terraformKeywords: Set<String> = [
    "check", "data", "for_each", "import", "locals", "module", "moved", "output", "provider",
    "provisioner", "resource", "terraform", "variable",
  ]
  private static let luaKeywords: Set<String> = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
  ]
  private static let powershellKeywords: Set<String> = [
    "begin", "class", "elseif", "else", "end", "filter", "foreach", "function", "if", "in",
    "param", "process", "return", "switch", "trap", "try", "while",
  ]
  private static let shellKeywords: Set<String> = [
    "case", "cd", "done", "do", "elif", "else", "esac", "export", "fi", "for", "function",
    "if", "in", "local", "then", "while",
  ]
  private static let defaultStringDelimiters = [QuotedDelimiter(quote: "\"", supportsEscapes: true)]
  private static let quotedStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
  ]
  private static let goStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
    QuotedDelimiter(quote: "`", supportsEscapes: false),
  ]
  // Template literals stay opaque on purpose; the lightweight highlighter does
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
  private static let jsonPunctuation: Set<Character> = ["{", "}", "[", "]", ":", ","]
  private static let ignorePatternOperators: Set<Character> = ["!", "*", "?", "[", "]"]

  static func highlights(_ source: String, language: HarnessCodeLanguage) -> HarnessCodeHighlights {
    SyntaxHighlightCache.shared.highlights(source, language: language) {
      highlightsUncached(source, language: language)
    }
  }

  static func highlightsUncached(_ source: String, language: HarnessCodeLanguage) -> HarnessCodeHighlights {
    switch language {
    case .codeowners:
      highlightCodeowners(source)
    case .config:
      highlightConfig(source)
    case .dockerfile:
      highlightCode(
        source,
        keywords: dockerfileKeywords,
        lineComments: ["#"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .diff:
      highlightDiff(source)
    case .feature:
      highlightFeature(source)
    case .generic:
      buildHighlights(
        source: source,
        spans: source.isEmpty ? [] : [.init(range: source.startIndex..<source.endIndex, kind: .plain)]
      )
    case .go:
      highlightCode(
        source,
        keywords: goKeywords,
        lineComment: "//",
        blockComment: true,
        stringDelimiters: goStringDelimiters
      )
    case .gitignore:
      highlightGitignore(source)
    case .goModule:
      highlightCode(
        source,
        keywords: goModuleKeywords,
        lineComments: ["//"],
        blockComment: false,
        stringDelimiters: goStringDelimiters
      )
    case .html:
      highlightVue(source)
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
    case .lua:
      highlightCode(
        source,
        keywords: luaKeywords,
        lineComments: ["--"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .makefile:
      highlightMakefile(source)
    case .markdown:
      highlightMarkdown(source)
    case .powershell:
      highlightCode(
        source,
        keywords: powershellKeywords,
        lineComments: ["#"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .proto:
      highlightCode(
        source,
        keywords: protoKeywords,
        lineComments: ["//"],
        blockComment: true,
        stringDelimiters: quotedStringDelimiters
      )
    case .python:
      highlightCode(
        source,
        keywords: pythonKeywords,
        lineComments: ["#"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .rego:
      highlightCode(
        source,
        keywords: regoKeywords,
        lineComments: ["#"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .rust:
      highlightCode(source, keywords: rustKeywords, lineComment: "//", blockComment: true)
    case .ruby:
      highlightCode(
        source,
        keywords: rubyKeywords,
        lineComments: ["#"],
        blockComment: false,
        stringDelimiters: quotedStringDelimiters
      )
    case .shell:
      highlightShell(source)
    case .sql:
      highlightCode(
        source,
        keywords: sqlKeywords,
        lineComments: ["--"],
        blockComment: true,
        stringDelimiters: quotedStringDelimiters
      )
    case .stylesheet:
      highlightCode(
        source,
        keywords: stylesheetKeywords,
        lineComments: ["//"],
        blockComment: true,
        stringDelimiters: quotedStringDelimiters
      )
    case .swift:
      highlightCode(source, keywords: swiftKeywords, lineComment: "//", blockComment: true)
    case .template:
      highlightTemplate(source)
    case .terraform:
      highlightCode(
        source,
        keywords: terraformKeywords,
        lineComments: ["#", "//"],
        blockComment: true,
        stringDelimiters: quotedStringDelimiters
      )
    case .toml:
      highlightTOML(source)
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
    case .xml:
      highlightVue(source)
    case .yaml:
      highlightYAML(source)
    }
  }

  static func highlight(_ source: String, language: HarnessCodeLanguage) -> [HarnessCodeToken] {
    highlights(source, language: language).tokens
  }

  static func makeAttributedString(
    from highlights: HarnessCodeHighlights,
    colors: HarnessCodeTokenColors = .default
  ) -> AttributedString {
    var rendered = AttributedString(highlights.source)
    for span in highlights.spans {
      guard
        let lower = AttributedString.Index(span.range.lowerBound, within: rendered),
        let upper = AttributedString.Index(span.range.upperBound, within: rendered)
      else {
        continue
      }
      rendered[lower..<upper].foregroundColor = colors.color(for: span.kind)
    }
    return rendered
  }

  private static func highlightCode(
    _ source: String,
    keywords: Set<String>,
    lineComment: String,
    blockComment: Bool,
    stringDelimiters: [QuotedDelimiter] = defaultStringDelimiters
  ) -> HarnessCodeHighlights {
    highlightCode(
      source,
      keywords: keywords,
      lineComments: [lineComment],
      blockComment: blockComment,
      stringDelimiters: stringDelimiters
    )
  }

  private static func highlightCode(
    _ source: String,
    keywords: Set<String>,
    lineComments: [String],
    blockComment: Bool,
    stringDelimiters: [QuotedDelimiter] = defaultStringDelimiters
  ) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      let character = source[index]
      if lineComments.contains(where: { starts($0, in: source, at: index) }) {
        appendUntilNewline(in: source, from: &index, kind: .comment, to: &spans)
      } else if blockComment, starts("/*", in: source, at: index) {
        appendBlockComment(in: source, from: &index, to: &spans)
      } else if let delimiter = stringDelimiter(matching: character, in: stringDelimiters) {
        appendQuoted(in: source, from: &index, delimiter: delimiter, to: &spans)
      } else if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if punctuation.contains(character) {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else if operators.contains(character) {
        appendCharacter(in: source, from: &index, kind: .operatorSymbol, to: &spans)
      } else if character.isNumber {
        appendRun(
          in: source,
          from: &index,
          while: { $0.isNumber || $0 == "." },
          kind: .number,
          to: &spans
        )
      } else if isIdentifierStart(character) {
        appendIdentifier(in: source, from: &index, keywords: keywords, to: &spans)
      } else {
        appendCharacter(in: source, from: &index, kind: .plain, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  private static func highlightShell(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      let character = source[index]
      if character == "#" {
        appendUntilNewline(in: source, from: &index, kind: .comment, to: &spans)
      } else if character == "\"" || character == "'" {
        appendQuoted(in: source, from: &index, to: &spans)
      } else if character == "$" {
        appendRun(
          in: source,
          from: &index,
          while: { isIdentifierPart($0) || $0 == "$" },
          kind: .literal,
          to: &spans
        )
      } else if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if isIdentifierStart(character) {
        appendIdentifier(in: source, from: &index, keywords: shellKeywords, to: &spans)
      } else {
        let kind: HarnessCodeToken.Kind = operators.contains(character) ? .operatorSymbol : .plain
        appendCharacter(in: source, from: &index, kind: kind, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  private static func highlightJSON(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      let character = source[index]
      if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if jsonPunctuation.contains(character) {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else if character == "\"" {
        let start = index
        let end = quotedEnd(in: source, start: index)
        let kind: HarnessCodeToken.Kind =
          nextNonWhitespace(in: source, from: end) == ":" ? .property : .string
        appendSpan(start..<end, kind: kind, to: &spans)
        index = end
      } else {
        appendJSONLiteral(in: source, from: &index, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  private static func highlightYAML(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      highlightYAMLLine(in: source, lineRange: lineRange, to: &spans)
    }
  }

  private static func highlightYAMLLine(
    in source: String,
    lineRange: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
    appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
    guard trimmedStart < lineRange.upperBound else { return }

    let trimmedRange = trimmedStart..<lineRange.upperBound
    if source[trimmedStart] == "#" {
      appendSpan(trimmedRange, kind: .comment, to: &spans)
      return
    }
    guard let colon = firstUnquotedColon(in: source, range: trimmedRange) else {
      appendSpan(trimmedRange, kind: .plain, to: &spans)
      return
    }

    appendSpan(trimmedStart..<colon, kind: .property, to: &spans)
    let colonEnd = source.index(after: colon)
    appendSpan(colon..<colonEnd, kind: .punctuation, to: &spans)
    if colonEnd < lineRange.upperBound {
      let remainder = colonEnd..<lineRange.upperBound
      appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
    }
  }

  private static func highlightDiff(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let text = source[lineRange]
      let kind: HarnessCodeToken.Kind =
        text.hasPrefix("@@")
        ? .heading : text.hasPrefix("+") ? .inserted : text.hasPrefix("-") ? .deleted : .plain
      appendSpan(lineRange, kind: kind, to: &spans)
    }
  }

  private static func highlightMarkdown(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      let kind: HarnessCodeToken.Kind =
        trimmedStart < lineRange.upperBound && source[trimmedStart] == "#" ? .heading : .plain
      appendSpan(lineRange, kind: kind, to: &spans)
    }
  }

  private static func highlightGitignore(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      appendIgnorePattern(in: source, range: trimmedRange, to: &spans)
    }
  }

  private static func highlightCodeowners(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      guard let boundary = source[trimmedRange].firstIndex(where: \.isWhitespace) else {
        appendIgnorePattern(in: source, range: trimmedRange, to: &spans)
        return
      }

      appendIgnorePattern(in: source, range: trimmedStart..<boundary, to: &spans)
      var index = boundary
      while index < lineRange.upperBound {
        let character = source[index]
        if character.isWhitespace {
          appendRun(
            in: source,
            from: &index,
            until: lineRange.upperBound,
            while: \.isWhitespace,
            kind: .whitespace,
            to: &spans
          )
        } else if character == "#" {
          appendSpan(index..<lineRange.upperBound, kind: .comment, to: &spans)
          index = lineRange.upperBound
        } else if character == "@" {
          appendRun(
            in: source,
            from: &index,
            until: lineRange.upperBound,
            while: { !$0.isWhitespace && $0 != "#" },
            kind: .property,
            to: &spans
          )
        } else {
          appendRun(
            in: source,
            from: &index,
            until: lineRange.upperBound,
            while: { !$0.isWhitespace && $0 != "#" },
            kind: .plain,
            to: &spans
          )
        }
      }
    }
  }

  private static func highlightMakefile(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let line = source[lineRange]
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if line.first == "\t" {
        appendSpan(trimmedRange, kind: .plain, to: &spans)
        return
      }
      if let directive = makefileDirectivePrefix(for: trimmed) {
        let boundary = source.index(trimmedStart, offsetBy: directive.count)
        appendSpan(trimmedStart..<boundary, kind: .keyword, to: &spans)
        if boundary < lineRange.upperBound {
          appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: [":=", "+=", "?=", "="]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .operatorSymbol, to: &spans)
        if range.upperBound < lineRange.upperBound {
          appendSpan(range.upperBound..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      if let colon = trimmed.firstIndex(of: ":") {
        appendSpan(trimmedStart..<colon, kind: .property, to: &spans)
        let afterColon = source.index(after: colon)
        appendSpan(colon..<afterColon, kind: .punctuation, to: &spans)
        if afterColon < lineRange.upperBound {
          appendSpan(afterColon..<lineRange.upperBound, kind: .plain, to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }

  private static func highlightConfig(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" || source[trimmedStart] == ";" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        appendSpan(trimmedRange, kind: .heading, to: &spans)
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: ["=", ":"]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .punctuation, to: &spans)
        if range.upperBound < lineRange.upperBound {
          let remainder = range.upperBound..<lineRange.upperBound
          appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }

  private static func highlightTOML(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: ()) { lineRange, _, spans in
      let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
      appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
      guard trimmedStart < lineRange.upperBound else { return }

      let trimmedRange = trimmedStart..<lineRange.upperBound
      let trimmed = source[trimmedRange]
      if source[trimmedStart] == "#" {
        appendSpan(trimmedRange, kind: .comment, to: &spans)
        return
      }
      if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
        appendSpan(trimmedRange, kind: .heading, to: &spans)
        return
      }
      if let (range, _) = firstSeparator(in: trimmed, separators: ["="]) {
        appendSpan(trimmedStart..<range.lowerBound, kind: .property, to: &spans)
        appendSpan(range, kind: .punctuation, to: &spans)
        if range.upperBound < lineRange.upperBound {
          let remainder = range.upperBound..<lineRange.upperBound
          appendSpan(remainder, kind: scalarKind(for: source[remainder]), to: &spans)
        }
        return
      }
      appendSpan(trimmedRange, kind: .plain, to: &spans)
    }
  }

  private static func highlightTemplate(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    while index < source.endIndex {
      if starts("{{/*", in: source, at: index) {
        appendThroughSequence("*/}}", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{!", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .literal, to: &spans)
      } else if source[index].isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendTemplateText(in: source, from: &index, to: &spans)
      }
    }
    return buildHighlights(source: source, spans: spans)
  }

  private static func highlightFeature(_ source: String) -> HarnessCodeHighlights {
    highlightLines(in: source, initialState: false) { lineRange, inDocstring, spans in
      highlightFeatureLine(in: source, lineRange: lineRange, inDocstring: &inDocstring, to: &spans)
    }
  }

  private static func highlightFeatureLine(
    in source: String,
    lineRange: Range<String.Index>,
    inDocstring: inout Bool,
    to spans: inout [HarnessCodeSpan]
  ) {
    let trimmedStart = leadingWhitespaceEnd(in: source, range: lineRange)
    appendSpan(lineRange.lowerBound..<trimmedStart, kind: .whitespace, to: &spans)
    guard trimmedStart < lineRange.upperBound else { return }

    let trimmedRange = trimmedStart..<lineRange.upperBound
    let trimmed = source[trimmedRange]
    if isFeatureDocstringDelimiter(trimmed) {
      inDocstring.toggle()
      appendSpan(trimmedRange, kind: .string, to: &spans)
      return
    }
    if inDocstring {
      appendSpan(trimmedRange, kind: .string, to: &spans)
      return
    }

    let lowercased = String(trimmed).lowercased()
    if lowercased.hasPrefix("#") {
      appendSpan(trimmedRange, kind: .comment, to: &spans)
      return
    }
    if lowercased.hasPrefix("@") {
      highlightFeatureTags(in: source, range: trimmedRange, to: &spans)
      return
    }
    if let prefix = featureSectionPrefixes.first(where: { lowercased.hasPrefix($0) }) {
      let boundary = source.index(trimmedStart, offsetBy: prefix.count)
      appendSpan(trimmedStart..<boundary, kind: .heading, to: &spans)
      if boundary < lineRange.upperBound {
        appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
      }
      return
    }
    if let stepPrefix = featureStepPrefix(for: trimmed) {
      let boundary = source.index(trimmedStart, offsetBy: stepPrefix.count)
      appendSpan(trimmedStart..<boundary, kind: .keyword, to: &spans)
      if boundary < lineRange.upperBound {
        appendSpan(boundary..<lineRange.upperBound, kind: .plain, to: &spans)
      }
      return
    }
    if source[trimmedStart] == "|" {
      highlightFeatureTable(in: source, range: trimmedRange, to: &spans)
      return
    }
    appendSpan(trimmedRange, kind: .plain, to: &spans)
  }

  private static func highlightFeatureTags(
    in source: String,
    range: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if character == "#" {
        appendSpan(index..<range.upperBound, kind: .comment, to: &spans)
        index = range.upperBound
      } else if character == "@" {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: { !$0.isWhitespace && $0 != "#" },
          kind: .property,
          to: &spans
        )
      } else {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: { !$0.isWhitespace && $0 != "#" },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  private static func highlightFeatureTable(
    in source: String,
    range: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character == "|" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: { !$0.isWhitespace && $0 != "|" },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  private static func highlightVue(_ source: String) -> HarnessCodeHighlights {
    var index = source.startIndex
    var spans: [HarnessCodeSpan] = []
    var rawSection: VueRawSection?

    while index < source.endIndex {
      if let currentRawSection = rawSection {
        if startsCaseInsensitive(currentRawSection.closingTag, in: source, at: index) {
          appendVueTag(in: source, from: &index, to: &spans, rawSection: &rawSection)
        } else {
          appendUntilCaseInsensitive(
            currentRawSection.closingTag,
            in: source,
            from: &index,
            kind: .plain,
            to: &spans
          )
        }
      } else if starts("<!--", in: source, at: index) {
        appendThroughSequence("-->", in: source, from: &index, kind: .comment, to: &spans)
      } else if starts("{{", in: source, at: index) {
        appendThroughSequence("}}", in: source, from: &index, kind: .literal, to: &spans)
      } else if source[index] == "<" {
        appendVueTag(in: source, from: &index, to: &spans, rawSection: &rawSection)
      } else if source[index].isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else {
        appendVueText(in: source, from: &index, to: &spans)
      }
    }

    return buildHighlights(source: source, spans: spans)
  }

  private static func appendVueTag(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan],
    rawSection: inout VueRawSection?
  ) {
    guard index < source.endIndex, source[index] == "<" else { return }
    appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)

    let isClosingTag = index < source.endIndex && source[index] == "/"
    if isClosingTag {
      appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
    }

    let tagStart = index
    while index < source.endIndex, isVueTagNameCharacter(source[index]) {
      source.formIndex(after: &index)
    }
    let tagRange = tagStart..<index
    let tagName = String(source[tagRange])
    if !tagName.isEmpty {
      appendSpan(tagRange, kind: .type, to: &spans)
    }
    let lowercasedTag = tagName.lowercased()

    while index < source.endIndex {
      if starts("/>", in: source, at: index) {
        appendSequence("/>", in: source, from: &index, kind: .punctuation, to: &spans)
        return
      }
      if source[index] == ">" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
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
      if source[index].isWhitespace {
        appendRun(
          in: source,
          from: &index,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if source[index] == "\"" || source[index] == "'" {
        appendQuoted(in: source, from: &index, to: &spans)
      } else if source[index] == "=" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else {
        let attributeStart = index
        while index < source.endIndex, isVueAttributeCharacter(source[index]) {
          source.formIndex(after: &index)
        }
        if attributeStart == index {
          appendCharacter(in: source, from: &index, kind: .plain, to: &spans)
        } else {
          appendSpan(attributeStart..<index, kind: .property, to: &spans)
        }
      }
    }
  }

  private static func appendVueText(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex,
      !source[index].isWhitespace,
      source[index] != "<",
      !starts("{{", in: source, at: index),
      !starts("<!--", in: source, at: index)
    {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: .plain, to: &spans)
  }

  private static func appendTemplateText(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex, !source[index].isWhitespace, !starts("{{", in: source, at: index) {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: .plain, to: &spans)
  }

  private static func appendRun(
    in source: String,
    from index: inout String.Index,
    while predicate: (Character) -> Bool,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendRun(
      in: source,
      from: &index,
      until: source.endIndex,
      while: predicate,
      kind: kind,
      to: &spans
    )
  }

  private static func appendRun(
    in source: String,
    from index: inout String.Index,
    until limit: String.Index,
    while predicate: (Character) -> Bool,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < limit, predicate(source[index]) {
      source.formIndex(after: &index)
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func appendCharacter(
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    source.formIndex(after: &index)
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func appendUntilNewline(
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendRun(in: source, from: &index, while: { $0 != "\n" }, kind: kind, to: &spans)
  }

  private static func appendBlockComment(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    index = source.index(index, offsetBy: 2)
    if let closingRange = source[index...].range(of: "*/") {
      index = closingRange.upperBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: .comment, to: &spans)
  }

  private static func appendQuoted(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    appendQuoted(
      in: source,
      from: &index,
      delimiter: QuotedDelimiter(quote: source[index], supportsEscapes: true),
      to: &spans
    )
  }

  private static func appendQuoted(
    in source: String,
    from index: inout String.Index,
    delimiter: QuotedDelimiter,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    let end = quotedEnd(in: source, start: index, delimiter: delimiter)
    appendSpan(start..<end, kind: .string, to: &spans)
    index = end
  }

  private static func appendIdentifier(
    in source: String,
    from index: inout String.Index,
    keywords: Set<String>,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    source.formIndex(after: &index)
    while index < source.endIndex, isIdentifierPart(source[index]) {
      source.formIndex(after: &index)
    }
    let text = String(source[start..<index])
    let kind: HarnessCodeToken.Kind =
      keywords.contains(text)
      ? .keyword
      : literals.contains(text) ? .literal : text.first?.isUppercase == true ? .type : .plain
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func appendJSONLiteral(
    in source: String,
    from index: inout String.Index,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    while index < source.endIndex,
      !source[index].isWhitespace,
      !jsonPunctuation.contains(source[index])
    {
      source.formIndex(after: &index)
    }
    let text = String(source[start..<index])
    let kind: HarnessCodeToken.Kind = literals.contains(text) ? .literal : .number
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func appendThroughSequence(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    if let range = source[index...].range(of: needle) {
      index = range.upperBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func appendSequence(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    guard let range = source[index...].range(of: needle, options: [.anchored]) else { return }
    index = range.upperBound
    appendSpan(range, kind: kind, to: &spans)
  }

  private static func appendUntilCaseInsensitive(
    _ needle: String,
    in source: String,
    from index: inout String.Index,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    let start = index
    if let range = source[index...].range(of: needle, options: [.caseInsensitive]) {
      index = range.lowerBound
    } else {
      index = source.endIndex
    }
    appendSpan(start..<index, kind: kind, to: &spans)
  }

  private static func quotedEnd(in source: String, start: String.Index) -> String.Index {
    quotedEnd(
      in: source,
      start: start,
      delimiter: QuotedDelimiter(quote: source[start], supportsEscapes: true)
    )
  }

  private static func quotedEnd(
    in source: String,
    start: String.Index,
    delimiter: QuotedDelimiter
  ) -> String.Index {
    var index = source.index(after: start)
    var escaped = false
    while index < source.endIndex {
      let character = source[index]
      source.formIndex(after: &index)
      if character == delimiter.closing, !escaped {
        return index
      }
      if delimiter.supportsEscapes {
        if character == "\\" {
          escaped.toggle()
        } else {
          escaped = false
        }
      }
    }
    return source.endIndex
  }

  private static func stringDelimiter(
    matching character: Character,
    in delimiters: [QuotedDelimiter]
  ) -> QuotedDelimiter? {
    delimiters.first { $0.opening == character }
  }

  private static func startsCaseInsensitive(
    _ needle: String,
    in source: String,
    at index: String.Index
  ) -> Bool {
    source[index...].range(of: needle, options: [.anchored, .caseInsensitive]) != nil
  }

  private static func starts(_ needle: String, in source: String, at index: String.Index) -> Bool {
    source[index...].hasPrefix(needle)
  }

  private static func nextNonWhitespace(in source: String, from index: String.Index) -> Character? {
    var candidate = index
    while candidate < source.endIndex {
      let character = source[candidate]
      if !character.isWhitespace { return character }
      source.formIndex(after: &candidate)
    }
    return nil
  }

  private static func firstUnquotedColon(
    in source: String,
    range: Range<String.Index>
  ) -> String.Index? {
    var quote: Character?
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character == "\"" || character == "'" {
        quote = quote == nil ? character : nil
      } else if character == ":", quote == nil {
        return index
      }
      source.formIndex(after: &index)
    }
    return nil
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character.isLetter || character == "_"
  }

  private static func isIdentifierPart(_ character: Character) -> Bool {
    character.isLetter || character.isNumber || character == "_"
  }

  private static func isFeatureDocstringDelimiter(_ line: Substring) -> Bool {
    line.hasPrefix("\"\"\"") || line.hasPrefix("```")
  }

  private static func featureStepPrefix(for line: Substring) -> String? {
    if line.hasPrefix("* ") || (line.count == 1 && line.first == "*") {
      return "*"
    }
    let lowercased = String(line).lowercased()
    for prefix in featureStepPrefixes {
      if lowercased == prefix || lowercased.hasPrefix("\(prefix) ") {
        return String(line.prefix(prefix.count))
      }
    }
    return nil
  }

  private static func leadingWhitespaceEnd(
    in source: String,
    range: Range<String.Index>
  ) -> String.Index {
    var index = range.lowerBound
    while index < range.upperBound, source[index].isWhitespace {
      source.formIndex(after: &index)
    }
    return index
  }

  private static func appendIgnorePattern(
    in source: String,
    range: Range<String.Index>,
    to spans: inout [HarnessCodeSpan]
  ) {
    var index = range.lowerBound
    while index < range.upperBound {
      let character = source[index]
      if character.isWhitespace {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: \.isWhitespace,
          kind: .whitespace,
          to: &spans
        )
      } else if character == "#" {
        appendSpan(index..<range.upperBound, kind: .comment, to: &spans)
        index = range.upperBound
      } else if ignorePatternOperators.contains(character) {
        appendCharacter(in: source, from: &index, kind: .operatorSymbol, to: &spans)
      } else if character == "/" {
        appendCharacter(in: source, from: &index, kind: .punctuation, to: &spans)
      } else {
        appendRun(
          in: source,
          from: &index,
          until: range.upperBound,
          while: { !$0.isWhitespace && $0 != "#" && !ignorePatternOperators.contains($0) && $0 != "/" },
          kind: .plain,
          to: &spans
        )
      }
    }
  }

  private static func makefileDirectivePrefix(for line: Substring) -> String? {
    let lowercased = String(line).lowercased()
    for prefix in makefileKeywords where lowercased == prefix || lowercased.hasPrefix("\(prefix) ") {
      return String(line.prefix(prefix.count))
    }
    return nil
  }

  private static func firstSeparator(
    in text: Substring,
    separators: [String]
  ) -> (Range<String.Index>, String)? {
    var bestMatch: (Range<String.Index>, String)?
    for separator in separators {
      guard let range = text.range(of: separator) else { continue }
      if let currentBestMatch = bestMatch {
        if range.lowerBound < currentBestMatch.0.lowerBound {
          bestMatch = (range, separator)
        }
      } else {
        bestMatch = (range, separator)
      }
    }
    return bestMatch
  }

  private static func scalarKind(for value: Substring) -> HarnessCodeToken.Kind {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      return .plain
    }
    let lowercased = trimmed.lowercased()
    if literals.contains(lowercased) || ["on", "off", "yes", "no"].contains(lowercased) {
      return .literal
    }
    if Double(trimmed) != nil {
      return .number
    }
    if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
      || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
      return .string
    }
    return .plain
  }

  private static func highlightLines<State>(
    in source: String,
    initialState: State,
    body: (Range<String.Index>, inout State, inout [HarnessCodeSpan]) -> Void
  ) -> HarnessCodeHighlights {
    guard !source.isEmpty else { return .empty }

    var state = initialState
    var spans: [HarnessCodeSpan] = []
    var lineStart = source.startIndex
    while lineStart < source.endIndex {
      let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
      body(lineStart..<lineEnd, &state, &spans)
      guard lineEnd < source.endIndex else { break }
      let nextStart = source.index(after: lineEnd)
      appendSpan(lineEnd..<nextStart, kind: .whitespace, to: &spans)
      lineStart = nextStart
    }
    return buildHighlights(source: source, spans: spans)
  }

  private static func appendSpan(
    _ range: Range<String.Index>,
    kind: HarnessCodeToken.Kind,
    to spans: inout [HarnessCodeSpan]
  ) {
    guard !range.isEmpty else { return }
    if let last = spans.last, last.kind == kind, last.range.upperBound == range.lowerBound {
      spans[spans.count - 1] = .init(range: last.range.lowerBound..<range.upperBound, kind: kind)
    } else {
      spans.append(.init(range: range, kind: kind))
    }
  }

  private static func buildHighlights(
    source: String,
    spans: [HarnessCodeSpan]
  ) -> HarnessCodeHighlights {
    guard !source.isEmpty else { return .empty }
    guard !spans.isEmpty else {
      return HarnessCodeHighlights(
        source: source,
        spans: [.init(range: source.startIndex..<source.endIndex, kind: .plain)]
      )
    }
    return HarnessCodeHighlights(source: source, spans: spans)
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
