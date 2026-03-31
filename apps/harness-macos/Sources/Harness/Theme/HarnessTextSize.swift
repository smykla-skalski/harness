import SwiftUI

// MARK: - Scale levels

enum HarnessTextSize {
  static let storageKey = "harnessTextSize"
  static let defaultIndex = 3

  static let scales: [(label: String, factor: CGFloat)] = [
    ("Extra small", 0.78),
    ("Small", 0.88),
    ("Medium", 0.94),
    ("Default", 1.0),
    ("Large", 1.08),
    ("Extra large", 1.18),
    ("Largest", 1.30),
  ]

  static func scale(at index: Int) -> CGFloat {
    guard scales.indices.contains(index) else { return 1.0 }
    return scales[index].factor
  }

  static func label(for index: Int) -> String {
    guard scales.indices.contains(index) else { return "Default" }
    return scales[index].label
  }

  static func canIncrease(_ index: Int) -> Bool {
    index < scales.count - 1
  }

  static func canDecrease(_ index: Int) -> Bool {
    index > 0
  }
}

// MARK: - Environment key

extension EnvironmentValues {
  @Entry var fontScale: CGFloat = 1.0
}

// MARK: - Scaled font modifier

private struct ScaledFontModifier: ViewModifier {
  let font: Font
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content.font(scale == 1.0 ? font : font.scaled(by: scale))
  }
}

extension View {
  func scaledFont(_ font: Font) -> some View {
    modifier(ScaledFontModifier(font: font))
  }
}
