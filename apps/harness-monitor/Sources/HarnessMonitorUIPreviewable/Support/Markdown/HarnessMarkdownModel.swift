import Foundation

struct HarnessMarkdownDocument: Equatable, Sendable {
  static let empty = Self(blocks: [])

  let blocks: [HarnessMarkdownBlock]
}

struct HarnessMarkdownAlert: Equatable, Sendable {
  enum Kind: String, CaseIterable, Equatable, Sendable {
    case note
    case tip
    case important
    case warning
    case caution

    init?(marker: String) {
      switch marker.lowercased() {
      case "note":
        self = .note
      case "tip":
        self = .tip
      case "important":
        self = .important
      case "warning":
        self = .warning
      case "caution":
        self = .caution
      default:
        return nil
      }
    }

    var title: String {
      switch self {
      case .note:
        "Note"
      case .tip:
        "Tip"
      case .important:
        "Important"
      case .warning:
        "Warning"
      case .caution:
        "Caution"
      }
    }

    var symbolName: String {
      switch self {
      case .note:
        "info.circle.fill"
      case .tip:
        "lightbulb.fill"
      case .important:
        "exclamationmark.circle.fill"
      case .warning:
        "exclamationmark.triangle.fill"
      case .caution:
        "exclamationmark.octagon.fill"
      }
    }
  }

  let kind: Kind
  let blocks: [HarnessMarkdownBlock]
}

indirect enum HarnessMarkdownBlock: Equatable, Sendable {
  case alert(HarnessMarkdownAlert)
  case blockQuote([Self])
  case codeBlock(language: HarnessCodeLanguage, highlights: HarnessCodeHighlights)
  case details(HarnessMarkdownDetails)
  case heading(level: Int, inlines: [HarnessMarkdownInline])
  case html([HarnessMarkdownInline])
  case orderedList(start: Int, items: [HarnessMarkdownListItem])
  case paragraph([HarnessMarkdownInline])
  case table(HarnessMarkdownTable)
  case thematicBreak
  case unorderedList([HarnessMarkdownListItem])
}

struct HarnessMarkdownListItem: Equatable, Sendable {
  let checkbox: Bool?
  let checkboxSourceOffset: Int?
  let blocks: [HarnessMarkdownBlock]

  init(
    checkbox: Bool?,
    checkboxSourceOffset: Int? = nil,
    blocks: [HarnessMarkdownBlock]
  ) {
    self.checkbox = checkbox
    self.checkboxSourceOffset = checkboxSourceOffset
    self.blocks = blocks
  }
}

struct HarnessMarkdownDetails: Equatable, Sendable {
  let summary: [HarnessMarkdownInline]
  let blocks: [HarnessMarkdownBlock]
  let isOpen: Bool
}

struct HarnessMarkdownTable: Equatable, Sendable {
  enum Alignment: Equatable, Sendable {
    case leading
    case center
    case trailing
  }

  let headers: [[HarnessMarkdownInline]]
  let alignments: [Alignment]
  let rows: [[[HarnessMarkdownInline]]]
}

indirect enum HarnessMarkdownInline: Equatable, Sendable {
  case autolink(String)
  case code(String)
  case emphasis([Self])
  case image(HarnessMarkdownImage)
  case lineBreak
  case link(label: [Self], destination: String, title: String?)
  case softBreak
  case strikethrough([Self])
  case strong([Self])
  case text(String)
}

struct HarnessMarkdownImage: Equatable, Sendable {
  let source: String
  let alt: String
  let title: String?
}

struct HarnessMarkdownReference: Equatable, Sendable {
  let destination: String
  let title: String?
}

enum HarnessMarkdownTextSelection: Sendable {
  case disabled
  case enabled
}

typealias HarnessMonitorMarkdownTextSelection = HarnessMarkdownTextSelection

enum HarnessMonitorMarkdownTextRendering: Hashable, Sendable {
  case rich
  case plainPreview
}

enum HarnessCodeLanguage: String, Equatable, Sendable {
  case codeowners
  case config
  case dockerfile
  case diff
  case feature
  case generic
  case go
  case gitignore
  case goModule
  case html
  case javascript
  case json
  case lua
  case makefile
  case markdown
  case powershell
  case proto
  case python
  case rego
  case rust
  case ruby
  case shell
  case sql
  case stylesheet
  case swift
  case template
  case terraform
  case toml
  case typescript
  case vue
  case xml
  case yaml

  private static let infoStringTagMap: [String: Self] = [
    "swift": .swift,
    "codeowners": .codeowners,
    "config": .config,
    "editorconfig": .config,
    "ini": .config,
    "procfile": .config,
    "systemd": .config,
    "containerfile": .dockerfile,
    "docker": .dockerfile,
    "dockerfile": .dockerfile,
    "cucumber": .feature,
    "feature": .feature,
    "gherkin": .feature,
    "go": .go,
    "golang": .go,
    "gitignore": .gitignore,
    "ignore": .gitignore,
    "go-module": .goModule,
    "go.mod": .goModule,
    "gomod": .goModule,
    "gosum": .goModule,
    "htm": .html,
    "html": .html,
    "cjs": .javascript,
    "javascript": .javascript,
    "js": .javascript,
    "jsx": .javascript,
    "mjs": .javascript,
    "node": .javascript,
    "nodejs": .javascript,
    "lua": .lua,
    "make": .makefile,
    "makefile": .makefile,
    "mk": .makefile,
    "rs": .rust,
    "rust": .rust,
    "powershell": .powershell,
    "ps1": .powershell,
    "pwsh": .powershell,
    "proto": .proto,
    "protobuf": .proto,
    "py": .python,
    "python": .python,
    "rego": .rego,
    "gemfile": .ruby,
    "rb": .ruby,
    "ruby": .ruby,
    "cts": .typescript,
    "ts": .typescript,
    "tsx": .typescript,
    "typescript": .typescript,
    "mts": .typescript,
    "bash": .shell,
    "console": .shell,
    "sh": .shell,
    "shell": .shell,
    "zsh": .shell,
    "json": .json,
    "jsonc": .json,
    "sql": .sql,
    "css": .stylesheet,
    "less": .stylesheet,
    "sass": .stylesheet,
    "scss": .stylesheet,
    "gotmpl": .template,
    "mustache": .template,
    "template": .template,
    "tmpl": .template,
    "tpl": .template,
    "hcl": .terraform,
    "terraform": .terraform,
    "tf": .terraform,
    "tfvars": .terraform,
    "toml": .toml,
    "yaml": .yaml,
    "yml": .yaml,
    "vue": .vue,
    "plist": .xml,
    "xml": .xml,
    "xsd": .xml,
    "xsl": .xml,
    "xslt": .xml,
    "diff": .diff,
    "patch": .diff,
    "markdown": .markdown,
    "md": .markdown,
  ]

  init(infoString: String?) {
    let tag =
      infoString?
      .split(whereSeparator: \.isWhitespace)
      .first?
      .lowercased() ?? ""
    let normalizedTag = tag.trimmingCharacters(in: CharacterSet(charactersIn: ".`"))
    self = Self.infoStringTagMap[normalizedTag] ?? .generic
  }

  var displayName: String? {
    switch self {
    case .diff:
      "Diff"
    case .codeowners:
      "CODEOWNERS"
    case .config:
      "Config"
    case .dockerfile:
      "Dockerfile"
    case .feature:
      "Feature"
    case .generic:
      nil
    case .go:
      "Go"
    case .gitignore:
      "Ignore"
    case .goModule:
      "Go module"
    case .html:
      "HTML"
    case .javascript:
      "JavaScript"
    case .json:
      "JSON"
    case .lua:
      "Lua"
    case .makefile:
      "Makefile"
    case .markdown:
      "Markdown"
    case .powershell:
      "PowerShell"
    case .proto:
      "Protocol Buffers"
    case .python:
      "Python"
    case .rego:
      "Rego"
    case .rust:
      "Rust"
    case .ruby:
      "Ruby"
    case .shell:
      "Shell"
    case .sql:
      "SQL"
    case .stylesheet:
      "Stylesheet"
    case .swift:
      "Swift"
    case .template:
      "Template"
    case .terraform:
      "Terraform/HCL"
    case .toml:
      "TOML"
    case .typescript:
      "TypeScript"
    case .vue:
      "Vue"
    case .xml:
      "XML"
    case .yaml:
      "YAML"
    }
  }
}

struct HarnessCodeToken: Equatable, Sendable {
  enum Kind: Equatable, Sendable {
    case comment
    case deleted
    case heading
    case inserted
    case keyword
    case literal
    case number
    case operatorSymbol
    case plain
    case property
    case punctuation
    case string
    case type
    case whitespace
  }

  let text: String
  let kind: Kind
}

struct HarnessCodeSpan: Sendable {
  let range: Range<String.Index>
  let kind: HarnessCodeToken.Kind
}

struct HarnessCodeHighlights: Equatable, Sendable {
  static let empty = Self(source: "", spans: [])

  let source: String
  let spans: [HarnessCodeSpan]

  var tokens: [HarnessCodeToken] {
    spans.map { span in
      HarnessCodeToken(text: String(source[span.range]), kind: span.kind)
    }
  }

  func contains(_ token: HarnessCodeToken) -> Bool {
    spans.contains { span in
      span.kind == token.kind && source[span.range] == token.text[...]
    }
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.source == rhs.source
      && lhs.spans.count == rhs.spans.count
      && zip(lhs.spans, rhs.spans).allSatisfy { lhsSpan, rhsSpan in
        lhsSpan.kind == rhsSpan.kind
          && lhs.source[lhsSpan.range] == rhs.source[rhsSpan.range]
      }
  }
}
