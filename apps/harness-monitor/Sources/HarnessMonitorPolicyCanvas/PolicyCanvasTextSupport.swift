import SwiftUI

extension EnvironmentValues {
  @Entry var fontScale: CGFloat = 1.0
}

private struct ScaledFontModifier: ViewModifier {
  let font: Font
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content.font(scale == 1.0 ? font : font.scaled(by: scale))
  }
}

private struct ClampedScaledFontModifier: ViewModifier {
  let font: Font
  let maxScale: CGFloat
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content.font(font.scaled(by: min(scale, maxScale)))
  }
}

extension View {
  func scaledFont(_ font: Font) -> some View {
    modifier(ScaledFontModifier(font: font))
  }

  func scaledFont(_ font: Font, maxScale: CGFloat) -> some View {
    modifier(ClampedScaledFontModifier(font: font, maxScale: maxScale))
  }
}
