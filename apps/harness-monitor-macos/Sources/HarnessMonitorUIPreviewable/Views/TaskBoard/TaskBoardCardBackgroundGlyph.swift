import SwiftUI

private struct TaskBoardCardBackgroundGlyphModifier: ViewModifier {
  let systemImage: String
  let tint: Color
  let cornerRadius: CGFloat
  @Environment(\.fontScale)
  private var fontScale

  private var glyphSize: CGFloat {
    82 * min(SessionWindowFontScale.metricsScale(for: fontScale), 1.18)
  }

  func body(content: Content) -> some View {
    content
      .background(alignment: .bottomTrailing) {
        Image(systemName: systemImage)
          .font(.system(size: glyphSize, weight: .black, design: .rounded))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(tint.opacity(0.22))
          .rotationEffect(.degrees(-8))
          .offset(x: 20, y: 24)
          .accessibilityHidden(true)
          .allowsHitTesting(false)
      }
      .clipShape(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
  }
}

extension View {
  func taskBoardCardBackgroundGlyph(
    systemImage: String,
    tint: Color,
    cornerRadius: CGFloat
  ) -> some View {
    modifier(
      TaskBoardCardBackgroundGlyphModifier(
        systemImage: systemImage,
        tint: tint,
        cornerRadius: cornerRadius
      )
    )
  }
}
