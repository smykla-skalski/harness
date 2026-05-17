import SwiftUI

struct PolicyCanvasEdgeLabelMetrics {
  let horizontalPadding: CGFloat
  let height: CGFloat
  private let defaultGlyphWidth: CGFloat
  private let narrowGlyphWidth: CGFloat
  private let wideGlyphWidth: CGFloat
  private let spaceWidth: CGFloat

  init(fontScale: CGFloat) {
    let scale = min(SessionWindowFontScale.metricsScale(for: fontScale), 1.45)
    spaceWidth = (3.5 * scale).rounded(.up)
    horizontalPadding = spaceWidth
    let textHeight = (11 * scale).rounded(.up)
    height = textHeight + (spaceWidth * 2)
    defaultGlyphWidth = 5.8 * scale
    narrowGlyphWidth = 3.7 * scale
    wideGlyphWidth = 7.2 * scale
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
    case 32, 45, 46, 47, 58:
      return spaceWidth
    case 73, 102, 105, 108, 114, 116:
      return narrowGlyphWidth
    case 77, 87, 109, 119:
      return wideGlyphWidth
    default:
      return defaultGlyphWidth
    }
  }
}
