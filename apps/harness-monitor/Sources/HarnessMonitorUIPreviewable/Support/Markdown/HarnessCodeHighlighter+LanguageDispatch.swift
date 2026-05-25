extension HarnessCodeHighlighter {
  struct CodeConfiguration {
    let keywords: Set<String>
    let lineComments: [String]
    let blockComment: Bool
    let stringDelimiters: [QuotedDelimiter]

    init(
      keywords: Set<String>,
      lineComments: [String],
      blockComment: Bool,
      stringDelimiters: [QuotedDelimiter]? = nil
    ) {
      self.keywords = keywords
      self.lineComments = lineComments
      self.blockComment = blockComment
      self.stringDelimiters = stringDelimiters ?? HarnessCodeHighlighter.defaultStringDelimiters
    }
  }

  typealias HighlightStrategy = @Sendable (String) -> HarnessCodeHighlights

  struct VueTagDescriptor {
    let isClosing: Bool
    let name: String
  }

  static let codeConfigurations: [HarnessCodeLanguage: CodeConfiguration] = [
    .dockerfile: .init(
      keywords: dockerfileKeywords,
      lineComments: ["#"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .go: .init(
      keywords: goKeywords,
      lineComments: ["//"],
      blockComment: true,
      stringDelimiters: goStringDelimiters
    ),
    .goModule: .init(
      keywords: goModuleKeywords,
      lineComments: ["//"],
      blockComment: false,
      stringDelimiters: goStringDelimiters
    ),
    .javascript: .init(
      keywords: javascriptKeywords,
      lineComments: ["//"],
      blockComment: true,
      stringDelimiters: scriptStringDelimiters
    ),
    .lua: .init(
      keywords: luaKeywords,
      lineComments: ["--"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .powershell: .init(
      keywords: powershellKeywords,
      lineComments: ["#"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .proto: .init(
      keywords: protoKeywords,
      lineComments: ["//"],
      blockComment: true,
      stringDelimiters: quotedStringDelimiters
    ),
    .python: .init(
      keywords: pythonKeywords,
      lineComments: ["#"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .rego: .init(
      keywords: regoKeywords,
      lineComments: ["#"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .rust: .init(
      keywords: rustKeywords,
      lineComments: ["//"],
      blockComment: true
    ),
    .ruby: .init(
      keywords: rubyKeywords,
      lineComments: ["#"],
      blockComment: false,
      stringDelimiters: quotedStringDelimiters
    ),
    .sql: .init(
      keywords: sqlKeywords,
      lineComments: ["--"],
      blockComment: true,
      stringDelimiters: quotedStringDelimiters
    ),
    .stylesheet: .init(
      keywords: stylesheetKeywords,
      lineComments: ["//"],
      blockComment: true,
      stringDelimiters: quotedStringDelimiters
    ),
    .swift: .init(
      keywords: swiftKeywords,
      lineComments: ["//"],
      blockComment: true
    ),
    .terraform: .init(
      keywords: terraformKeywords,
      lineComments: ["#", "//"],
      blockComment: true,
      stringDelimiters: quotedStringDelimiters
    ),
    .typescript: .init(
      keywords: typescriptKeywords,
      lineComments: ["//"],
      blockComment: true,
      stringDelimiters: scriptStringDelimiters
    ),
  ]
  static let specialHighlighters: [HarnessCodeLanguage: HighlightStrategy] = [
    .codeowners: { highlightCodeowners($0) },
    .config: { highlightConfig($0) },
    .diff: { highlightDiff($0) },
    .feature: { highlightFeature($0) },
    .generic: { highlightGeneric($0) },
    .gitignore: { highlightGitignore($0) },
    .html: { highlightVue($0) },
    .json: { highlightJSON($0) },
    .makefile: { highlightMakefile($0) },
    .markdown: { highlightMarkdown($0) },
    .shell: { highlightShell($0) },
    .template: { highlightTemplate($0) },
    .toml: { highlightTOML($0) },
    .vue: { highlightVue($0) },
    .xml: { highlightVue($0) },
    .yaml: { highlightYAML($0) },
  ]

  static func highlightsUncached(
    _ source: String, language: HarnessCodeLanguage
  ) -> HarnessCodeHighlights {
    if let configuration = codeConfigurations[language] {
      return highlightCode(source, configuration: configuration)
    }

    return specialHighlighters[language]?(source) ?? highlightGeneric(source)
  }

  static func highlightGeneric(_ source: String) -> HarnessCodeHighlights {
    buildHighlights(
      source: source,
      spans: source.isEmpty
        ? [] : [.init(range: source.startIndex..<source.endIndex, kind: .plain)]
    )
  }

  static func highlightCode(
    _ source: String,
    configuration: CodeConfiguration
  ) -> HarnessCodeHighlights {
    highlightCode(
      source,
      keywords: configuration.keywords,
      lineComments: configuration.lineComments,
      blockComment: configuration.blockComment,
      stringDelimiters: configuration.stringDelimiters
    )
  }
}
