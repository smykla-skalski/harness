import AppKit
import HarnessMonitorKit

@MainActor
enum DashboardReviewFileDiffHighlightCache {
  private struct Key: Hashable {
    let text: String
    let language: String
    let pointSize: CGFloat
  }

  private static var storage: [Key: NSAttributedString] = [:]
  private static var insertionOrder: [Key] = []
  private static let capacity = 2_000

  static func attributed(
    text: String,
    language: HarnessCodeLanguage,
    font: NSFont
  ) -> NSAttributedString {
    let key = Key(text: text, language: language.rawValue, pointSize: font.pointSize)
    if let cached = storage[key] {
      return cached
    }
    let result = render(text: text, language: language, font: font)
    storage[key] = result
    insertionOrder.append(key)
    evictIfNeeded()
    return result
  }

  private static func render(
    text: String,
    language: HarnessCodeLanguage,
    font: NSFont
  ) -> NSAttributedString {
    let tokens = HarnessCodeHighlighter.highlight(text, language: language)
    let result = NSMutableAttributedString()
    for token in tokens {
      result.append(
        NSAttributedString(
          string: token.text,
          attributes: [.font: font, .foregroundColor: tokenColor(for: token.kind)]
        )
      )
    }
    return result
  }

  private static func evictIfNeeded() {
    while insertionOrder.count > capacity {
      storage.removeValue(forKey: insertionOrder.removeFirst())
    }
  }

  private static func tokenColor(for kind: HarnessCodeToken.Kind) -> NSColor {
    switch kind {
    case .comment: .secondaryLabelColor
    case .keyword, .property: .controlAccentColor
    case .literal, .number, .type: .systemOrange
    case .operatorSymbol, .punctuation, .whitespace: .tertiaryLabelColor
    case .string: .systemGreen
    case .deleted: .systemRed
    case .heading, .inserted: .controlAccentColor
    case .plain: .labelColor
    }
  }
}
