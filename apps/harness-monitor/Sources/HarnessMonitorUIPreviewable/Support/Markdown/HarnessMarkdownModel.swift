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

  init(infoString: String?) {
    let tag =
      infoString?
      .split(whereSeparator: \.isWhitespace)
      .first?
      .lowercased() ?? ""

    switch tag.trimmingCharacters(in: CharacterSet(charactersIn: ".`")) {
    case "swift":
      self = .swift
    case "codeowners":
      self = .codeowners
    case "config", "editorconfig", "ini", "procfile", "systemd":
      self = .config
    case "containerfile", "docker", "dockerfile":
      self = .dockerfile
    case "cucumber", "feature", "gherkin":
      self = .feature
    case "go", "golang":
      self = .go
    case "gitignore", "ignore":
      self = .gitignore
    case "go-module", "go.mod", "gomod", "gosum":
      self = .goModule
    case "htm", "html":
      self = .html
    case "cjs", "javascript", "js", "jsx", "mjs", "node", "nodejs":
      self = .javascript
    case "lua":
      self = .lua
    case "make", "makefile", "mk":
      self = .makefile
    case "rs", "rust":
      self = .rust
    case "powershell", "ps1", "pwsh":
      self = .powershell
    case "proto", "protobuf":
      self = .proto
    case "py", "python":
      self = .python
    case "rego":
      self = .rego
    case "gemfile", "rb", "ruby":
      self = .ruby
    case "cts", "ts", "tsx", "typescript", "mts":
      self = .typescript
    case "bash", "console", "sh", "shell", "zsh":
      self = .shell
    case "json", "jsonc":
      self = .json
    case "sql":
      self = .sql
    case "css", "less", "sass", "scss":
      self = .stylesheet
    case "gotmpl", "mustache", "template", "tmpl", "tpl":
      self = .template
    case "hcl", "terraform", "tf", "tfvars":
      self = .terraform
    case "toml":
      self = .toml
    case "yaml", "yml":
      self = .yaml
    case "vue":
      self = .vue
    case "plist", "xml", "xsd", "xsl", "xslt":
      self = .xml
    case "diff", "patch":
      self = .diff
    case "markdown", "md":
      self = .markdown
    default:
      self = .generic
    }
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
