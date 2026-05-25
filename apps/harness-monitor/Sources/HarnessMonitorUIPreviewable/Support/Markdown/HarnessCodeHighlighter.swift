import SwiftUI

enum HarnessCodeHighlighter {
  struct QuotedDelimiter {
    let opening: Character
    let closing: Character
    let supportsEscapes: Bool

    init(quote: Character, supportsEscapes: Bool) {
      opening = quote
      closing = quote
      self.supportsEscapes = supportsEscapes
    }
  }

  enum VueRawSection: String {
    case script
    case style

    var closingTag: String { "</\(rawValue)" }
  }

  static let swiftKeywords: Set<String> = [
    "actor", "as", "async", "await", "case", "catch", "class", "enum", "extension", "for",
    "func", "guard", "if", "import", "in", "init", "let", "nil", "private", "public",
    "return", "self", "static", "struct", "switch", "throw", "try", "var", "while",
  ]
  static let rustKeywords: Set<String> = [
    "async", "await", "const", "crate", "enum", "false", "fn", "for", "if", "impl", "let",
    "match", "mod", "mut", "pub", "return", "self", "struct", "true", "use", "where",
  ]
  static let goKeywords: Set<String> = [
    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
    "return", "select", "struct", "switch", "type", "var",
  ]
  static let javascriptKeywords: Set<String> = [
    "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
    "default", "delete", "do", "else", "export", "extends", "false", "finally", "for",
    "from", "function", "if", "import", "in", "instanceof", "let", "new", "null", "of",
    "return", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "var",
    "void", "while", "yield",
  ]
  static let typescriptKeywords: Set<String> = javascriptKeywords.union([
    "abstract", "any", "as", "asserts", "boolean", "declare", "enum", "implements", "infer",
    "interface", "is", "keyof", "module", "namespace", "never", "number", "object", "private",
    "protected", "public", "readonly", "satisfies", "string", "symbol", "type", "typeof",
    "undefined", "unique", "unknown",
  ])
  static let featureSectionPrefixes = [
    "scenario outline:",
    "scenario template:",
    "background:",
    "examples:",
    "scenario:",
    "feature:",
    "example:",
    "rule:",
  ]
  static let featureStepPrefixes = ["given", "when", "then", "and", "but"]
  static let dockerfileKeywords: Set<String> = [
    "add", "arg", "cmd", "copy", "entrypoint", "env", "expose", "from", "healthcheck", "label",
    "onbuild", "run", "shell", "stopsignal", "user", "volume", "workdir",
    "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK", "LABEL",
    "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR",
  ]
  static let goModuleKeywords: Set<String> = [
    "exclude", "go", "module", "replace", "require", "retract", "toolchain",
  ]
  static let makefileKeywords: Set<String> = [
    "define", "else", "endef", "endif", "export", "ifdef", "ifndef", "ifeq", "ifneq", "include",
    "override", "private", "undefine", "unexport",
  ]
  static let protoKeywords: Set<String> = [
    "enum", "extend", "extensions", "import", "message", "oneof", "option", "optional",
    "package", "repeated", "required", "returns", "rpc", "service", "syntax",
  ]
  static let pythonKeywords: Set<String> = [
    "and", "as", "async", "await", "class", "def", "elif", "else", "except", "False", "for",
    "from", "if", "import", "in", "is", "lambda", "None", "not", "or", "pass", "raise",
    "return", "True", "try", "while", "with", "yield",
  ]
  static let regoKeywords: Set<String> = [
    "contains", "default", "deny", "else", "every", "false", "if", "import", "in", "not",
    "null", "package", "some", "true", "with",
  ]
  static let rubyKeywords: Set<String> = [
    "alias", "begin", "case", "class", "def", "do", "else", "elsif", "end", "ensure", "false",
    "if", "module", "nil", "require", "rescue", "return", "self", "super", "then", "true",
    "unless", "when", "while", "yield",
  ]
  static let sqlKeywords: Set<String> = [
    "alter", "and", "as", "by", "create", "delete", "drop", "from", "group", "having",
    "insert", "into", "join", "limit", "not", "null", "on", "or", "order", "select", "set",
    "table", "union", "update", "values", "where",
    "ALTER", "AND", "AS", "BY", "CREATE", "DELETE", "DROP", "FROM", "GROUP", "HAVING",
    "INSERT", "INTO", "JOIN", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "SELECT", "SET",
    "TABLE", "UNION", "UPDATE", "VALUES", "WHERE",
  ]
  static let stylesheetKeywords: Set<String> = [
    "charset", "container", "font-face", "forward", "import", "include", "keyframes", "media",
    "mixin", "namespace", "supports", "use",
  ]
  static let terraformKeywords: Set<String> = [
    "check", "data", "for_each", "import", "locals", "module", "moved", "output", "provider",
    "provisioner", "resource", "terraform", "variable",
  ]
  static let luaKeywords: Set<String> = [
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
  ]
  static let powershellKeywords: Set<String> = [
    "begin", "class", "elseif", "else", "end", "filter", "foreach", "function", "if", "in",
    "param", "process", "return", "switch", "trap", "try", "while",
  ]
  static let shellKeywords: Set<String> = [
    "case", "cd", "done", "do", "elif", "else", "esac", "export", "fi", "for", "function",
    "if", "in", "local", "then", "while",
  ]
  static let defaultStringDelimiters = [QuotedDelimiter(quote: "\"", supportsEscapes: true)]
  static let quotedStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
  ]
  static let goStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
    QuotedDelimiter(quote: "`", supportsEscapes: false),
  ]
  // Template literals stay opaque on purpose; the lightweight highlighter does
  // not attempt to parse nested `${...}` expressions inside them.
  static let scriptStringDelimiters = [
    QuotedDelimiter(quote: "\"", supportsEscapes: true),
    QuotedDelimiter(quote: "'", supportsEscapes: true),
    QuotedDelimiter(quote: "`", supportsEscapes: true),
  ]
  static let literals: Set<String> = ["false", "nil", "null", "true"]
  static let punctuation: Set<Character> = ["(", ")", "[", "]", "{", "}", ",", ".", ":"]
  static let operators: Set<Character> = [
    "=", "+", "-", "*", "/", "%", "!", "<", ">", "&", "|", "^", "~", "?",
  ]
  static let jsonPunctuation: Set<Character> = ["{", "}", "[", "]", ":", ","]
  static let ignorePatternOperators: Set<Character> = ["!", "*", "?", "[", "]"]

  static func highlights(_ source: String, language: HarnessCodeLanguage) -> HarnessCodeHighlights {
    SyntaxHighlightCache.shared.highlights(source, language: language) {
      highlightsUncached(source, language: language)
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

  static func highlightCode(
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

  static func highlightCode(
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
}
