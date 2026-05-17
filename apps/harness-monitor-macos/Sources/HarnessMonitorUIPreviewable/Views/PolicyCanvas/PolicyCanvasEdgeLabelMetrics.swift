import SwiftUI

struct PolicyCanvasEdgeLabelMetrics {
  let horizontalPadding: CGFloat
  let height: CGFloat
  private let defaultGlyphWidth: CGFloat
  private let tallGlyphWidth: CGFloat
  private let narrowGlyphWidth: CGFloat
  private let thinGlyphWidth: CGFloat
  private let mediumWideGlyphWidth: CGFloat
  private let wideGlyphWidth: CGFloat
  private let spaceWidth: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    spaceWidth = (3.5 * scale).rounded(.up)
    horizontalPadding = spaceWidth
    let textHeight = (11 * scale).rounded(.up)
    height = textHeight + (spaceWidth * 2)
    defaultGlyphWidth = 6.6 * scale
    tallGlyphWidth = 7.1 * scale
    narrowGlyphWidth = 4.7 * scale
    thinGlyphWidth = 3.2 * scale
    mediumWideGlyphWidth = 9.2 * scale
    wideGlyphWidth = 10.2 * scale
  }

  func size(for label: String) -> CGSize {
    let textWidth = label.unicodeScalars.reduce(CGFloat.zero) { width, scalar in
      width + estimatedWidth(for: scalar)
    }
    return CGSize(
      width: min(
        PolicyCanvasLayout.edgeLabelMaxWidth,
        max(1, textWidth.rounded(.up) + (horizontalPadding * 2))
      ),
      height: height
    )
  }

  func frame(for label: String, center: CGPoint) -> CGRect {
    let labelSize = size(for: label)
    return CGRect(
      x: center.x - (labelSize.width / 2),
      y: center.y - (labelSize.height / 2),
      width: labelSize.width,
      height: labelSize.height
    )
  }

  private func estimatedWidth(for scalar: Unicode.Scalar) -> CGFloat {
    switch scalar.value {
    case 32:
      return spaceWidth
    case 46, 47, 58:
      return thinGlyphWidth
    case 45:
      return narrowGlyphWidth
    case 73, 105, 108:
      return thinGlyphWidth
    case 102, 114, 116:
      return narrowGlyphWidth
    case 98, 100, 103, 104, 107, 110, 112, 113, 117, 121:
      return tallGlyphWidth
    case 77, 87, 109:
      return wideGlyphWidth
    case 119:
      return mediumWideGlyphWidth
    default:
      return defaultGlyphWidth
    }
  }
}
