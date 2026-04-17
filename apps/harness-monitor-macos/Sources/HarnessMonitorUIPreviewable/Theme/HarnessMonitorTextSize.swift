import SwiftUI

// MARK: - Scale levels

public enum HarnessMonitorTextSize {
  public static let storageKey = "harnessTextSize"
  public static let uiTestOverrideKey = "HARNESS_MONITOR_TEXT_SIZE_OVERRIDE"
  public static let defaultIndex = 3

  public static let scales: [(label: String, factor: CGFloat)] = [
    ("Extra small", 0.78),
    ("Small", 0.88),
    ("Medium", 0.94),
    ("Default", 1.0),
    ("Large", 1.08),
    ("Extra large", 1.18),
    ("Largest", 1.30),
  ]

  public static func normalizedIndex(_ index: Int) -> Int {
    min(max(index, scales.startIndex), scales.index(before: scales.endIndex))
  }

  public static func scale(at index: Int) -> CGFloat {
    scales[normalizedIndex(index)].factor
  }

  public static func label(for index: Int) -> String {
    scales[normalizedIndex(index)].label
  }

  public static func nativeFormControlFont(at index: Int) -> Font {
    let font = Font.body
    return scaledFont(font, by: scale(at: index))
  }

  public static func scaledFont(_ font: Font, by scale: CGFloat) -> Font {
    scale == 1.0 ? font : font.scaled(by: scale)
  }

  public static func controlSize(at index: Int) -> ControlSize {
    switch normalizedIndex(index) {
    case ...3:
      .small
    case 4...5:
      .regular
    default:
      .large
    }
  }

  public static func controlSizeLabel(at index: Int) -> String {
    switch normalizedIndex(index) {
    case ...3:
      "small"
    case 4...5:
      "regular"
    default:
      "large"
    }
  }

  public static func uiTestOverrideIndex(from rawValue: String?) -> Int? {
    guard let rawValue, let parsedIndex = Int(rawValue) else { return nil }
    return normalizedIndex(parsedIndex)
  }

  public static func canIncrease(_ index: Int) -> Bool {
    index < scales.count - 1
  }

  public static func canDecrease(_ index: Int) -> Bool {
    index > 0
  }

  /// Returns the index step (-1, 0, or +1) for a completed magnify gesture.
  ///
  /// `magnification` is the raw gesture value where 1.0 means no change,
  /// values above 1.0 mean pinch-out (zoom in), and below 1.0 mean
  /// pinch-in (zoom out). The step only fires when the absolute change
  /// exceeds `threshold`, preventing accidental triggers from scroll gestures.
  public static func indexDelta(
    forMagnification magnification: CGFloat,
    currentIndex: Int,
    threshold: CGFloat = 0.15
  ) -> Int {
    let change = magnification - 1.0
    if change > threshold && canIncrease(currentIndex) {
      return 1
    } else if change < -threshold && canDecrease(currentIndex) {
      return -1
    }
    return 0
  }
}

// MARK: - Environment key

extension EnvironmentValues {
  @Entry public var fontScale: CGFloat = 1.0
  @Entry public var harnessTextSizeIndex: Int = HarnessMonitorTextSize.defaultIndex
  @Entry public var harnessNativeFormControlFont: Font = .body
  @Entry public var harnessNativeFormControlSize: ControlSize = .small
}

// MARK: - Scaled font modifier

private struct ScaledFontModifier: ViewModifier {
  let font: Font
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content.font(HarnessMonitorTextSize.scaledFont(font, by: scale))
  }
}

private struct HarnessMonitorNativeFormControlModifier: ViewModifier {
  @Environment(\.harnessNativeFormControlFont)
  private var font
  @Environment(\.harnessNativeFormControlSize)
  private var controlSize

  func body(content: Content) -> some View {
    content
      .font(font)
      .controlSize(controlSize)
  }
}

private struct HarnessMonitorFormContainerModifier: ViewModifier {
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content
      .font(HarnessMonitorTextSize.scaledFont(.body, by: scale))
      .formStyle(.grouped)
      .scrollIndicators(.automatic)
  }
}

extension View {
  public func scaledFont(_ font: Font) -> some View {
    modifier(ScaledFontModifier(font: font))
  }

  public func harnessNativeFormControl() -> some View {
    modifier(HarnessMonitorNativeFormControlModifier())
  }

  public func harnessNativeFormContainer() -> some View {
    modifier(HarnessMonitorFormContainerModifier())
  }
}
