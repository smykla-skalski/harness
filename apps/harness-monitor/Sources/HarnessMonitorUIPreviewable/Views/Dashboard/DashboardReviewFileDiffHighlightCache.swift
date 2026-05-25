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
    let highlights = HarnessCodeHighlighter.highlights(text, language: language)
    let result = NSMutableAttributedString(
      string: highlights.source,
      attributes: [.font: font]
    )
    for span in highlights.spans {
      result.addAttribute(
        .foregroundColor,
        value: tokenColor(for: span.kind),
        range: NSRange(span.range, in: highlights.source)
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
    DashboardReviewFileDiffMonokaiPalette.tokenColor(for: kind)
  }
}

enum DashboardReviewFileDiffMonokaiPalette {
  static let background = nsColor(hex: 0x272822)
  static let foreground = nsColor(hex: 0xF8F8F2)
  static let comment = nsColor(hex: 0x75715E)
  static let selection = nsColor(hex: 0x49483E)
  static let red = nsColor(hex: 0xF92672)
  static let orange = nsColor(hex: 0xFD971F)
  static let yellow = nsColor(hex: 0xE6DB74)
  static let green = nsColor(hex: 0xA6E22E)
  static let blue = nsColor(hex: 0x66D9EF)
  static let purple = nsColor(hex: 0xAE81FF)

  static let contextBackground = background
  static let additionBackground = nsColor(hex: 0x34481F)
  static let deletionBackground = nsColor(hex: 0x4A2031)
  static let hunkBackground = nsColor(hex: 0x293C40)
  static let contextGapBackground = nsColor(hex: 0x33342B)
  static let metadataBackground = nsColor(hex: 0x45341F)
  static let separator = nsColor(hex: 0x3E3D32)

  static func tokenColor(for kind: HarnessCodeToken.Kind) -> NSColor {
    switch kind {
    case .comment:
      comment
    case .keyword, .operatorSymbol:
      red
    case .literal, .number:
      purple
    case .property, .type:
      blue
    case .punctuation, .whitespace:
      comment
    case .string:
      yellow
    case .deleted:
      red
    case .heading:
      orange
    case .inserted:
      green
    case .plain:
      foreground
    }
  }

  private static func nsColor(hex: UInt32) -> NSColor {
    let red = CGFloat((hex >> 16) & 0xFF) / 255
    let green = CGFloat((hex >> 8) & 0xFF) / 255
    let blue = CGFloat(hex & 0xFF) / 255
    return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
  }
}
