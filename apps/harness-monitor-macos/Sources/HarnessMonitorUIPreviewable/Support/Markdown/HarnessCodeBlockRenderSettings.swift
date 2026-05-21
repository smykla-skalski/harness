import SwiftUI

struct HarnessCodeBlockRenderSettings {
  var typography: HarnessCodeBlockTypography
  var colors: HarnessCodeBlockColorSettings
  var fontScaleMode: HarnessMarkdownFontScaleMode

  init(
    typography: HarnessCodeBlockTypography = .default,
    colors: HarnessCodeBlockColorSettings = .default,
    fontScaleMode: HarnessMarkdownFontScaleMode = .environment
  ) {
    self.typography = typography
    self.colors = colors
    self.fontScaleMode = fontScaleMode
  }

  static let `default` = HarnessCodeBlockRenderSettings()

  func resolved(environmentFontScale: CGFloat) -> HarnessCodeBlockResolvedSettings {
    let scale = fontScaleMode.resolvedScale(environmentFontScale: environmentFontScale)
    return HarnessCodeBlockResolvedSettings(
      typography: typography.resolved(scale: scale),
      colors: colors
    )
  }

  func withFontScaleMode(_ mode: HarnessMarkdownFontScaleMode) -> HarnessCodeBlockRenderSettings {
    var copy = self
    copy.fontScaleMode = mode
    return copy
  }
}

struct HarnessCodeBlockTypography {
  var code: HarnessMarkdownFontStyle
  var label: HarnessMarkdownFontStyle
  var error: HarnessMarkdownFontStyle

  static let `default` = HarnessCodeBlockTypography(
    code: .system(size: 12, design: .monospaced),
    label: .system(size: 11, weight: .semibold),
    error: .system(size: 12, weight: .semibold)
  )

  func resolved(scale: CGFloat) -> HarnessCodeBlockResolvedTypography {
    HarnessCodeBlockResolvedTypography(
      code: code.resolved(scale: scale),
      label: label.resolved(scale: scale),
      error: error.resolved(scale: scale)
    )
  }
}

struct HarnessCodeBlockResolvedSettings {
  let typography: HarnessCodeBlockResolvedTypography
  let colors: HarnessCodeBlockColorSettings
}

struct HarnessCodeBlockResolvedTypography {
  let code: HarnessMarkdownResolvedFontStyle
  let label: HarnessMarkdownResolvedFontStyle
  let error: HarnessMarkdownResolvedFontStyle
}

struct HarnessCodeBlockColorSettings {
  var label: Color
  var error: Color
  var background: Color
  var border: Color
  var tokens: HarnessCodeTokenColors

  static let `default` = HarnessCodeBlockColorSettings(
    label: HarnessMonitorTheme.secondaryInk,
    error: HarnessMonitorTheme.danger,
    background: HarnessMonitorTheme.ink,
    border: HarnessMonitorTheme.controlBorder,
    tokens: .default
  )
}

struct HarnessCodeTokenColors {
  var comment: Color
  var deleted: Color
  var heading: Color
  var inserted: Color
  var keyword: Color
  var literal: Color
  var number: Color
  var operatorSymbol: Color
  var plain: Color
  var property: Color
  var punctuation: Color
  var string: Color
  var type: Color
  var whitespace: Color

  static let `default` = HarnessCodeTokenColors(
    comment: HarnessMonitorTheme.secondaryInk,
    deleted: HarnessMonitorTheme.danger,
    heading: HarnessMonitorTheme.accent,
    inserted: HarnessMonitorTheme.success,
    keyword: HarnessMonitorTheme.accent,
    literal: HarnessMonitorTheme.caution,
    number: HarnessMonitorTheme.warmAccent,
    operatorSymbol: HarnessMonitorTheme.tertiaryInk,
    plain: HarnessMonitorTheme.ink,
    property: HarnessMonitorTheme.accent,
    punctuation: HarnessMonitorTheme.tertiaryInk,
    string: HarnessMonitorTheme.success,
    type: HarnessMonitorTheme.warmAccent,
    whitespace: HarnessMonitorTheme.tertiaryInk
  )

  func color(for kind: HarnessCodeToken.Kind) -> Color {
    switch kind {
    case .comment:
      comment
    case .deleted:
      deleted
    case .heading:
      heading
    case .inserted:
      inserted
    case .keyword:
      keyword
    case .literal:
      literal
    case .number:
      number
    case .operatorSymbol:
      operatorSymbol
    case .plain:
      plain
    case .property:
      property
    case .punctuation:
      punctuation
    case .string:
      string
    case .type:
      type
    case .whitespace:
      whitespace
    }
  }
}
