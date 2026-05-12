import Foundation
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

  public static func nativeInputIndex(_ index: Int) -> Int {
    normalizedIndex(index)
  }

  public static func nativeInputFont(at index: Int) -> Font {
    nativeFormControlFont(at: index)
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

  public static func nativeInputControlSize(at index: Int) -> ControlSize {
    controlSize(at: index)
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

private struct ClampedScaledFontModifier: ViewModifier {
  let font: Font
  let maxScale: CGFloat
  @Environment(\.fontScale)
  private var scale

  func body(content: Content) -> some View {
    content.font(HarnessMonitorTextSize.scaledFont(font, by: min(scale, maxScale)))
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

private struct HarnessMonitorNativeTextFieldModifier: ViewModifier {
  @Environment(\.harnessTextSizeIndex)
  private var textSizeIndex

  func body(content: Content) -> some View {
    content
      .multilineTextAlignment(.leading)
      .font(HarnessMonitorTextSize.nativeInputFont(at: textSizeIndex))
      .controlSize(HarnessMonitorTextSize.nativeInputControlSize(at: textSizeIndex))
      .textFieldStyle(.roundedBorder)
      .frame(maxWidth: .infinity)
  }
}

private struct HarnessMonitorNativeFormSectionHeaderModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .scaledFont(.caption.weight(.semibold))
      .accessibilityAddTraits(.isHeader)
  }
}

private struct HarnessMonitorNativeFormSectionFooterModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.scaledFont(.caption)
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

  public func scaledFont(_ font: Font, maxScale: CGFloat) -> some View {
    modifier(ClampedScaledFontModifier(font: font, maxScale: maxScale))
  }

  public func harnessNativeFormControl() -> some View {
    modifier(HarnessMonitorNativeFormControlModifier())
  }

  public func harnessNativeTextField() -> some View {
    modifier(HarnessMonitorNativeTextFieldModifier())
  }

  public func harnessNativeFormSectionHeader() -> some View {
    modifier(HarnessMonitorNativeFormSectionHeaderModifier())
  }

  public func harnessNativeFormSectionFooter() -> some View {
    modifier(HarnessMonitorNativeFormSectionFooterModifier())
  }

  public func harnessNativeFormContainer() -> some View {
    modifier(HarnessMonitorFormContainerModifier())
  }

  func harnessPreviewSceneAppearance(
    themeMode: HarnessMonitorThemeMode = .dark,
    textSizeIndex: Int = HarnessMonitorTextSize.defaultIndex,
    dateTimeConfiguration: HarnessMonitorDateTimeConfiguration = .default
  ) -> some View {
    modifier(
      HarnessMonitorPreviewSceneAppearanceModifier(
        defaultThemeMode: themeMode,
        defaultTextSizeIndex: textSizeIndex,
        defaultDateTimeConfiguration: dateTimeConfiguration
      )
    )
  }
}

private enum HarnessMonitorPreviewSceneOverrides {
  static let themeModeKey = "HARNESS_MONITOR_THEME_MODE_OVERRIDE"
  static let overrideFileName = "HarnessMonitorPreviewOverrides.json"
  static let overrideMaximumAge: TimeInterval = 15 * 60
  static let overridePollIntervalNanoseconds: UInt64 = 100_000_000

  static var overrideFileURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("tmp")
      .appendingPathComponent("previews")
      .appendingPathComponent(overrideFileName)
  }

  static var fallbackOverrideFileURL: URL {
    URL(fileURLWithPath: "/tmp")
      .appendingPathComponent(overrideFileName)
  }

  static var overrideFileURLs: [URL] {
    [overrideFileURL, fallbackOverrideFileURL]
  }
}

private struct HarnessMonitorPreviewOverrideFile: Decodable, Equatable {
  let themeMode: String?
  let textSizeIndex: Int?
  let timeZoneMode: String?
  let customTimeZone: String?
  let generatedAt: TimeInterval?

  enum CodingKeys: String, CodingKey {
    case themeMode = "theme_mode"
    case textSizeIndex = "text_size_index"
    case timeZoneMode = "time_zone_mode"
    case customTimeZone = "custom_time_zone"
    case generatedAt = "generated_at"
  }

  static func load() -> Self? {
    for url in HarnessMonitorPreviewSceneOverrides.overrideFileURLs {
      guard let data = try? Data(contentsOf: url),
        let override = try? JSONDecoder().decode(Self.self, from: data),
        !override.isExpired
      else {
        continue
      }
      return override
    }
    return nil
  }

  private var isExpired: Bool {
    guard let generatedAt else {
      return false
    }
    return Date().timeIntervalSince1970 - generatedAt
      > HarnessMonitorPreviewSceneOverrides.overrideMaximumAge
  }
}

private struct HarnessMonitorPreviewSceneAppearanceModifier: ViewModifier {
  let defaultThemeMode: HarnessMonitorThemeMode
  let defaultTextSizeIndex: Int
  let defaultDateTimeConfiguration: HarnessMonitorDateTimeConfiguration
  @State private var fileOverride = HarnessMonitorPreviewOverrideFile.load()

  private var environment: [String: String] {
    ProcessInfo.processInfo.environment
  }

  private var overrideThemeModeRawValue: String? {
    fileOverride?.themeMode
      ?? environment[HarnessMonitorPreviewSceneOverrides.themeModeKey]
  }

  private var overrideTextSizeIndexRawValue: String? {
    fileOverride?.textSizeIndex.map(String.init)
      ?? environment[HarnessMonitorTextSize.uiTestOverrideKey]
  }

  private var overrideTimeZoneModeRawValue: String? {
    fileOverride?.timeZoneMode
      ?? environment[HarnessMonitorDateTimeConfiguration.uiTestTimeZoneModeOverrideKey]
  }

  private var overrideCustomTimeZoneIdentifier: String? {
    fileOverride?.customTimeZone
      ?? environment[HarnessMonitorDateTimeConfiguration.uiTestCustomTimeZoneOverrideKey]
  }

  private var resolvedThemeMode: HarnessMonitorThemeMode {
    HarnessMonitorThemeMode(
      rawValue: overrideThemeModeRawValue ?? ""
    ) ?? defaultThemeMode
  }

  private var resolvedTextSizeIndex: Int {
    HarnessMonitorTextSize.uiTestOverrideIndex(
      from: overrideTextSizeIndexRawValue
    ) ?? HarnessMonitorTextSize.normalizedIndex(defaultTextSizeIndex)
  }

  private var resolvedDateTimeConfiguration: HarnessMonitorDateTimeConfiguration {
    HarnessMonitorDateTimeConfiguration(
      timeZoneModeRawValue: overrideTimeZoneModeRawValue
        ?? defaultDateTimeConfiguration.timeZoneModeRawValue,
      customTimeZoneIdentifier: overrideCustomTimeZoneIdentifier
        ?? defaultDateTimeConfiguration.customTimeZoneIdentifier
    )
  }

  func body(content: Content) -> some View {
    content
      .environment(\.harnessTextSizeIndex, resolvedTextSizeIndex)
      .sessionFontScale(textSizeIndex: resolvedTextSizeIndex)
      .environment(
        \.harnessNativeFormControlFont,
        HarnessMonitorTextSize.nativeFormControlFont(at: resolvedTextSizeIndex)
      )
      .environment(
        \.harnessNativeFormControlSize,
        HarnessMonitorTextSize.controlSize(at: resolvedTextSizeIndex)
      )
      .environment(\.harnessDateTimeConfiguration, resolvedDateTimeConfiguration)
      .preferredColorScheme(resolvedThemeMode.colorScheme)
      .tint(HarnessMonitorTheme.accent)
      .task {
        await refreshFileOverrideLoop()
      }
  }

  @MainActor
  private func refreshFileOverrideLoop() async {
    while !Task.isCancelled {
      let nextOverride = HarnessMonitorPreviewOverrideFile.load()
      if fileOverride != nextOverride {
        fileOverride = nextOverride
      }
      try? await Task.sleep(
        nanoseconds: HarnessMonitorPreviewSceneOverrides.overridePollIntervalNanoseconds
      )
    }
  }
}
