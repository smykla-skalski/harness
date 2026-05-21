import Foundation

struct HarnessMarkdownDocument: Equatable, Sendable {
  static let empty = Self(blocks: [])

  let blocks: [HarnessMarkdownBlock]
}

indirect enum HarnessMarkdownBlock: Equatable, Sendable {
  case blockQuote([Self])
  case codeBlock(language: HarnessCodeLanguage, source: String, tokens: [HarnessCodeToken])
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
  let blocks: [HarnessMarkdownBlock]
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
  case diff
  case generic
  case json
  case markdown
  case rust
  case shell
  case swift
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
    case "rs", "rust":
      self = .rust
    case "bash", "console", "sh", "shell", "zsh":
      self = .shell
    case "json", "jsonc":
      self = .json
    case "yaml", "yml":
      self = .yaml
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
    case .generic:
      nil
    case .json:
      "JSON"
    case .markdown:
      "Markdown"
    case .rust:
      "Rust"
    case .shell:
      "Shell"
    case .swift:
      "Swift"
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
