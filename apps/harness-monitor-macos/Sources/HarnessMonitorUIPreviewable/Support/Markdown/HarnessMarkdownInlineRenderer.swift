import Foundation
import SwiftUI

enum HarnessMarkdownInlineRenderer {
  static func attributedString(
    from inlines: [HarnessMarkdownInline],
    font: Font,
    codeFont: Font? = nil
  ) -> AttributedString {
    let style = HarnessMarkdownInlineRenderStyle(
      font: font,
      codeFont: codeFont ?? font.monospaced(),
      colors: .default
    )
    return attributedString(from: inlines, style: style)
  }

  static func attributedString(
    from inlines: [HarnessMarkdownInline],
    style: HarnessMarkdownInlineRenderStyle
  ) -> AttributedString {
    inlines.reduce(into: AttributedString()) { result, inline in
      result += fragment(for: inline, style: style)
    }
  }

  private static func fragment(
    for inline: HarnessMarkdownInline,
    style: HarnessMarkdownInlineRenderStyle
  ) -> AttributedString {
    switch inline {
    case .autolink(let value):
      return linked(value, label: value, style: style)
    case .code(let value):
      var fragment = AttributedString(value)
      fragment.font = style.codeFont
      fragment.foregroundColor = style.colors.inlineCodeText
      fragment.backgroundColor = style.colors.inlineCodeBackground
      return fragment
    case .emphasis(let children):
      var fragment = attributedString(from: children, style: style.withFont(style.font.italic()))
      fragment.font = style.font.italic()
      return fragment
    case .image(let image):
      let label = image.alt.isEmpty ? image.source : image.alt
      return linked(image.source, label: label, style: style)
    case .lineBreak:
      return AttributedString("\n")
    case .link(let label, let destination, _):
      var fragment = attributedString(from: label, style: style)
      if let url = URL(string: destination) {
        fragment.link = url
      }
      fragment.foregroundColor = style.colors.link
      fragment.underlineStyle = .single
      return fragment
    case .softBreak:
      return AttributedString(" ")
    case .strikethrough(let children):
      var fragment = attributedString(from: children, style: style)
      fragment.strikethroughStyle = .single
      return fragment
    case .strong(let children):
      var fragment = attributedString(from: children, style: style.withFont(style.font.bold()))
      fragment.font = style.font.bold()
      return fragment
    case .text(let value):
      var fragment = AttributedString(value)
      fragment.font = style.font
      fragment.foregroundColor = style.colors.text
      return fragment
    }
  }

  private static func linked(
    _ destination: String,
    label: String,
    style: HarnessMarkdownInlineRenderStyle
  ) -> AttributedString {
    var fragment = AttributedString(label)
    fragment.font = style.font
    fragment.foregroundColor = style.colors.link
    if let url = URL(string: destination) {
      fragment.link = url
    }
    fragment.underlineStyle = .single
    return fragment
  }
}
