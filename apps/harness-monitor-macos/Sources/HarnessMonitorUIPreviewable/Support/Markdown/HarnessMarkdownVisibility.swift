import Foundation

extension HarnessMarkdownListItem {
  var rendersVisibleContent: Bool {
    blocks.contains { $0.rendersVisibleMarkdownContent }
  }
}

extension HarnessMarkdownBlock {
  var rendersVisibleMarkdownContent: Bool {
    switch self {
    case .blockQuote(let blocks):
      blocks.contains { $0.rendersVisibleMarkdownContent }
    case .codeBlock(_, let source, _):
      !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .details(let details):
      details.summary.contains { $0.rendersVisibleMarkdownContent }
        || details.blocks.contains { $0.rendersVisibleMarkdownContent }
    case .heading(_, let inlines), .html(let inlines), .paragraph(let inlines):
      inlines.contains { $0.rendersVisibleMarkdownContent }
    case .orderedList(_, let items), .unorderedList(let items):
      items.contains { $0.rendersVisibleContent }
    case .table(let table):
      table.headers.containsVisibleMarkdownContent
        || table.rows.contains { $0.containsVisibleMarkdownContent }
    case .thematicBreak:
      true
    }
  }
}

extension HarnessMarkdownInline {
  var rendersVisibleMarkdownContent: Bool {
    switch self {
    case .autolink, .code, .image:
      true
    case .emphasis(let children), .strikethrough(let children), .strong(let children):
      children.contains { $0.rendersVisibleMarkdownContent }
    case .lineBreak, .softBreak:
      false
    case .link(let label, let destination, _):
      !destination.isEmpty || label.contains { $0.rendersVisibleMarkdownContent }
    case .text(let value):
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  var containsMarkdownImage: Bool {
    switch self {
    case .image:
      true
    case .emphasis(let children), .link(let children, _, _), .strikethrough(let children),
      .strong(let children):
      children.contains { $0.containsMarkdownImage }
    case .autolink, .code, .lineBreak, .softBreak, .text:
      false
    }
  }
}

extension [HarnessMarkdownInline] {
  var containsMarkdownImage: Bool {
    contains { $0.containsMarkdownImage }
  }

  var isStandaloneMarkdownImage: Bool {
    let visible = filter { $0.rendersVisibleMarkdownContent }
    guard visible.count == 1 else { return false }
    switch visible[0] {
    case .image:
      return true
    case .link(let label, _, _):
      return label.isStandaloneMarkdownImage
    case .autolink, .code, .emphasis, .lineBreak, .softBreak, .strikethrough, .strong, .text:
      return false
    }
  }
}

extension [[HarnessMarkdownInline]] {
  var containsVisibleMarkdownContent: Bool {
    contains { $0.contains { $0.rendersVisibleMarkdownContent } }
  }
}
