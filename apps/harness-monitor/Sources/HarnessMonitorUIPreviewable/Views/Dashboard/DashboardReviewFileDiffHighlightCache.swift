import AppKit
import CoreText
import HarnessMonitorKit

struct DashboardReviewFileDiffTextLineLayout {
  let attributedString: NSAttributedString
  let line: CTLine
  let glyphBounds: CGRect
  let typographicWidth: CGFloat

  static func make(attributedString: NSAttributedString) -> Self {
    let line = CTLineCreateWithAttributedString(attributedString)
    let glyphBounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    return Self(
      attributedString: attributedString,
      line: line,
      glyphBounds: glyphBounds,
      typographicWidth: typographicWidth
    )
  }
}

@MainActor
enum DashboardReviewFileDiffHighlightCache {
  private struct Key: Hashable {
    let text: String
    let language: String
    let pointSize: CGFloat
  }

  private static var storage: [Key: DashboardReviewFileDiffTextLineLayout] = [:]
  private static var insertionOrder: [Key] = []
  private static let capacity = 2_000

  static func layout(
    text: String,
    language: HarnessCodeLanguage,
    font: NSFont
  ) -> DashboardReviewFileDiffTextLineLayout {
    let key = Key(
      text: text,
      language: language.rawValue,
      pointSize: font.pointSize
    )
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
  ) -> DashboardReviewFileDiffTextLineLayout {
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
    return DashboardReviewFileDiffTextLineLayout.make(attributedString: result)
  }

  static func layout(
    visualLine: DashboardReviewFileDiffWrappedVisualLine,
    highlightSpans: [DashboardReviewFileDiffWrappedHighlightSpan],
    font: NSFont
  ) -> DashboardReviewFileDiffTextLineLayout {
    let renderedText =
      String(repeating: " ", count: visualLine.leadingIndentColumns) + visualLine.text
    let attributedString = NSMutableAttributedString(
      string: renderedText,
      attributes: [
        .font: font,
        .foregroundColor: DashboardReviewFileDiffMonokaiPalette.foreground,
      ]
    )
    if let sourceOffsets = visualLine.sourceOffsets {
      for span in highlightSpans {
        let lower = max(span.range.lowerBound, sourceOffsets.lowerBound)
        let upper = min(span.range.upperBound, sourceOffsets.upperBound)
        guard lower < upper else { continue }
        attributedString.addAttribute(
          .foregroundColor,
          value: tokenColor(for: span.kind),
          range: NSRange(
            location: visualLine.leadingIndentColumns + lower - sourceOffsets.lowerBound,
            length: upper - lower
          )
        )
      }
    }
    return DashboardReviewFileDiffTextLineLayout.make(
      attributedString: attributedString
    )
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

@MainActor
enum DashboardReviewFileDiffPlainTextCache {
  private struct Key: Hashable {
    let text: String
    let pointSize: CGFloat
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8
  }

  private static var storage: [Key: DashboardReviewFileDiffTextLineLayout] = [:]
  private static var insertionOrder: [Key] = []
  private static let capacity = 2_000

  static func layout(
    text: String,
    font: NSFont,
    color: NSColor
  ) -> DashboardReviewFileDiffTextLineLayout? {
    guard !text.isEmpty else { return nil }
    let components = color.usingColorSpace(.deviceRGB) ?? color
    let key = Key(
      text: text,
      pointSize: font.pointSize,
      red: UInt8((components.redComponent * 255).rounded()),
      green: UInt8((components.greenComponent * 255).rounded()),
      blue: UInt8((components.blueComponent * 255).rounded()),
      alpha: UInt8((components.alphaComponent * 255).rounded())
    )
    if let cached = storage[key] {
      return cached
    }
    let attributedString = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color,
      ]
    )
    let layout = DashboardReviewFileDiffTextLineLayout.make(
      attributedString: attributedString
    )
    storage[key] = layout
    insertionOrder.append(key)
    evictIfNeeded()
    return layout
  }

  private static func evictIfNeeded() {
    while insertionOrder.count > capacity {
      storage.removeValue(forKey: insertionOrder.removeFirst())
    }
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
