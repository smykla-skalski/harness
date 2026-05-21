import SwiftUI

struct HarnessMarkdownParagraphView: View {
  let inlines: [HarnessMarkdownInline]
  let style: HarnessMarkdownResolvedRenderSettings

  var body: some View {
    if let leadingEmoji = HarnessMarkdownLeadingEmoji(inlines: inlines) {
      let metrics = HarnessMarkdownMarkerMetrics(style: style)
      HStack(alignment: .top, spacing: metrics.gap) {
        Text(verbatim: leadingEmoji.emoji)
          .font(style.typography.body.font)
          .frame(width: metrics.columnWidth, height: metrics.firstLineHeight, alignment: .center)
        inlineFlow(leadingEmoji.remaining)
      }
    } else {
      inlineFlow(inlines)
    }
  }

  private func inlineFlow(_ inlines: [HarnessMarkdownInline]) -> some View {
    HarnessMarkdownInlineFlowView(
      inlines: inlines,
      style: HarnessMarkdownInlineRenderStyle(
        font: style.typography.body.font,
        codeFont: style.typography.inlineCode.font,
        colors: style.colors
      ),
      images: style.images
    )
  }
}

struct HarnessMarkdownLeadingEmoji {
  let emoji: String
  let remaining: [HarnessMarkdownInline]

  init?(inlines: [HarnessMarkdownInline]) {
    guard case .text(let text)? = inlines.first else { return nil }
    let characters = Array(text)
    guard let first = characters.first, first.isMarkdownLeadingEmoji else { return nil }
    let restStart = characters.index(after: characters.startIndex)
    guard restStart < characters.endIndex, characters[restStart].isWhitespace else { return nil }
    var remaining = Array(inlines.dropFirst())
    let restText = String(characters[restStart...]).trimmingLeadingMarkdownSpaces()
    if !restText.isEmpty {
      remaining.insert(.text(restText), at: 0)
    }
    guard !remaining.isEmpty else { return nil }
    self.emoji = String(first)
    self.remaining = remaining
  }
}

extension Character {
  fileprivate var isMarkdownLeadingEmoji: Bool {
    unicodeScalars.contains { scalar in
      scalar.properties.isEmojiPresentation
        || scalar.properties.isEmoji && !scalar.properties.isAlphabetic && !scalar.properties.isMath
    }
  }
}

extension String {
  fileprivate func trimmingLeadingMarkdownSpaces() -> String {
    var result = self
    while result.first?.isWhitespace == true {
      result.removeFirst()
    }
    return result
  }
}
