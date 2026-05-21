import Foundation
import SwiftUI

enum HarnessMarkdownInlineRenderer {
  static func attributedString(
    from inlines: [HarnessMarkdownInline],
    font: Font,
    codeFont: Font? = nil
  ) -> AttributedString {
    inlines.reduce(into: AttributedString()) { result, inline in
      result += fragment(for: inline, font: font, codeFont: codeFont ?? font.monospaced())
    }
  }

  private static func fragment(
    for inline: HarnessMarkdownInline,
    font: Font,
    codeFont: Font
  ) -> AttributedString {
    switch inline {
    case .autolink(let value):
      return linked(value, label: value, font: font)
    case .code(let value):
      var fragment = AttributedString(value)
      fragment.font = codeFont
      fragment.foregroundColor = HarnessMonitorTheme.ink
      fragment.backgroundColor = HarnessMonitorTheme.accent.opacity(0.10)
      return fragment
    case .emphasis(let children):
      var fragment = attributedString(from: children, font: font.italic(), codeFont: codeFont)
      fragment.font = font.italic()
      return fragment
    case .lineBreak:
      return AttributedString("\n")
    case .link(let label, let destination, _):
      var fragment = attributedString(from: label, font: font, codeFont: codeFont)
      if let url = URL(string: destination) {
        fragment.link = url
      }
      fragment.foregroundColor = HarnessMonitorTheme.accent
      fragment.underlineStyle = .single
      return fragment
    case .softBreak:
      return AttributedString(" ")
    case .strikethrough(let children):
      var fragment = attributedString(from: children, font: font, codeFont: codeFont)
      fragment.strikethroughStyle = .single
      return fragment
    case .strong(let children):
      var fragment = attributedString(from: children, font: font.bold(), codeFont: codeFont)
      fragment.font = font.bold()
      return fragment
    case .text(let value):
      var fragment = AttributedString(value)
      fragment.font = font
      fragment.foregroundColor = HarnessMonitorTheme.ink
      return fragment
    }
  }

  private static func linked(_ destination: String, label: String, font: Font) -> AttributedString {
    var fragment = AttributedString(label)
    fragment.font = font
    fragment.foregroundColor = HarnessMonitorTheme.accent
    if let url = URL(string: destination) {
      fragment.link = url
    }
    fragment.underlineStyle = .single
    return fragment
  }
}
