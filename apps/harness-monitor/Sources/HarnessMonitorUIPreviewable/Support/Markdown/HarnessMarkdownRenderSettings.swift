import SwiftUI

enum HarnessMarkdownFontScaleMode {
  case environment
  case explicit(CGFloat)
  case fixed

  func resolvedScale(environmentFontScale: CGFloat) -> CGFloat {
    let scale: CGFloat
    switch self {
    case .environment:
      scale = environmentFontScale
    case .explicit(let explicitScale):
      scale = explicitScale
    case .fixed:
      scale = 1
    }
    return scale.isFinite ? max(scale, 0.1) : 1
  }
}

struct HarnessMarkdownRenderSettings {
  var typography: HarnessMarkdownTypography
  var colors: HarnessMarkdownColorSettings
  var codeBlock: HarnessCodeBlockRenderSettings
  var images: HarnessMarkdownImageSettings
  var spacing: HarnessMarkdownSpacingSettings
  var fontScaleMode: HarnessMarkdownFontScaleMode

  init(
    typography: HarnessMarkdownTypography = .default,
    colors: HarnessMarkdownColorSettings = .default,
    codeBlock: HarnessCodeBlockRenderSettings = .default,
    images: HarnessMarkdownImageSettings = .default,
    spacing: HarnessMarkdownSpacingSettings = .default,
    fontScaleMode: HarnessMarkdownFontScaleMode = .environment
  ) {
    self.typography = typography
    self.colors = colors
    self.images = images
    self.spacing = spacing
    self.fontScaleMode = fontScaleMode
    self.codeBlock = codeBlock.withFontScaleMode(fontScaleMode)
  }

  static let `default` = Self()

  static func sized(
    body: CGFloat = 13,
    inlineCode: CGFloat = 12,
    heading1: CGFloat = 20,
    heading2: CGFloat = 17,
    heading3: CGFloat = 15,
    headingDefault: CGFloat = 13,
    fontScaleMode: HarnessMarkdownFontScaleMode = .environment,
    colors: HarnessMarkdownColorSettings = .default,
    codeBlock: HarnessCodeBlockRenderSettings = .default,
    images: HarnessMarkdownImageSettings = .default,
    spacing: HarnessMarkdownSpacingSettings = .default
  ) -> Self {
    Self(
      typography: HarnessMarkdownTypography(
        body: .system(size: body),
        inlineCode: .system(size: inlineCode, design: .monospaced),
        heading1: .system(size: heading1, weight: .semibold),
        heading2: .system(size: heading2, weight: .semibold),
        heading3: .system(size: heading3, weight: .semibold),
        headingDefault: .system(size: headingDefault, weight: .semibold),
        listMarker: .system(size: body),
        tableHeader: .system(size: body, weight: .semibold)
      ),
      colors: colors,
      codeBlock: codeBlock,
      images: images,
      spacing: spacing,
      fontScaleMode: fontScaleMode
    )
  }

  func withBodyFont(_ font: Font) -> Self {
    var copy = self
    copy.typography.body = .font(font)
    copy.typography.inlineCode = .font(font.monospaced())
    copy.typography.listMarker = .font(font)
    copy.typography.tableHeader = .font(font.weight(.semibold))
    return copy
  }

  func resolved(environmentFontScale: CGFloat) -> HarnessMarkdownResolvedRenderSettings {
    let scale = fontScaleMode.resolvedScale(environmentFontScale: environmentFontScale)
    return HarnessMarkdownResolvedRenderSettings(
      typography: typography.resolved(scale: scale),
      colors: colors,
      codeBlock: codeBlock,
      images: images.scaled(by: scale),
      spacing: spacing.scaled(by: scale)
    )
  }
}

struct HarnessMarkdownTypography {
  var body: HarnessMarkdownFontStyle
  var inlineCode: HarnessMarkdownFontStyle
  var heading1: HarnessMarkdownFontStyle
  var heading2: HarnessMarkdownFontStyle
  var heading3: HarnessMarkdownFontStyle
  var headingDefault: HarnessMarkdownFontStyle
  var listMarker: HarnessMarkdownFontStyle
  var tableHeader: HarnessMarkdownFontStyle

  static let `default` = Self(
    body: .system(size: 13),
    inlineCode: .system(size: 12, design: .monospaced),
    heading1: .system(size: 20, weight: .semibold),
    heading2: .system(size: 17, weight: .semibold),
    heading3: .system(size: 15, weight: .semibold),
    headingDefault: .system(size: 13, weight: .semibold),
    listMarker: .system(size: 13),
    tableHeader: .system(size: 13, weight: .semibold)
  )

  func resolved(scale: CGFloat) -> HarnessMarkdownResolvedTypography {
    HarnessMarkdownResolvedTypography(
      body: body.resolved(scale: scale),
      inlineCode: inlineCode.resolved(scale: scale),
      heading1: heading1.resolved(scale: scale),
      heading2: heading2.resolved(scale: scale),
      heading3: heading3.resolved(scale: scale),
      headingDefault: headingDefault.resolved(scale: scale),
      listMarker: listMarker.resolved(scale: scale),
      tableHeader: tableHeader.resolved(scale: scale)
    )
  }
}

struct HarnessMarkdownResolvedRenderSettings {
  let typography: HarnessMarkdownResolvedTypography
  let colors: HarnessMarkdownColorSettings
  let codeBlock: HarnessCodeBlockRenderSettings
  let images: HarnessMarkdownImageSettings
  let spacing: HarnessMarkdownSpacingSettings
}

struct HarnessMarkdownResolvedTypography {
  let body: HarnessMarkdownResolvedFontStyle
  let inlineCode: HarnessMarkdownResolvedFontStyle
  let heading1: HarnessMarkdownResolvedFontStyle
  let heading2: HarnessMarkdownResolvedFontStyle
  let heading3: HarnessMarkdownResolvedFontStyle
  let headingDefault: HarnessMarkdownResolvedFontStyle
  let listMarker: HarnessMarkdownResolvedFontStyle
  let tableHeader: HarnessMarkdownResolvedFontStyle
}

struct HarnessMarkdownResolvedFontStyle {
  let font: Font
  let pointSize: CGFloat?
}

struct HarnessMarkdownFontStyle {
  private let baseFont: Font?
  private let pointSize: CGFloat
  private let weight: Font.Weight?
  private let design: Font.Design
  private let isItalic: Bool

  static func system(
    size: CGFloat,
    weight: Font.Weight? = nil,
    design: Font.Design = .default
  ) -> Self {
    Self(
      baseFont: nil,
      pointSize: size,
      weight: weight,
      design: design,
      isItalic: false
    )
  }

  static func font(_ font: Font) -> Self {
    Self(
      baseFont: font,
      pointSize: 0,
      weight: nil,
      design: .default,
      isItalic: false
    )
  }

  func resolved(scale: CGFloat) -> HarnessMarkdownResolvedFontStyle {
    if let baseFont {
      return HarnessMarkdownResolvedFontStyle(
        font: HarnessMonitorTextSize.scaledFont(baseFont, by: scale),
        pointSize: nil
      )
    }
    let scaledSize = max(1, pointSize * scale)
    var font = Font.system(size: scaledSize, weight: weight, design: design)
    if isItalic {
      font = font.italic()
    }
    return HarnessMarkdownResolvedFontStyle(font: font, pointSize: scaledSize)
  }

  func scaledPointSize(scale: CGFloat) -> CGFloat? {
    baseFont == nil ? max(1, pointSize * scale) : nil
  }

  func bold() -> Self {
    weighted(.bold)
  }

  func italic() -> Self {
    if let baseFont {
      return .font(baseFont.italic())
    }
    return Self(
      baseFont: nil,
      pointSize: pointSize,
      weight: weight,
      design: design,
      isItalic: true
    )
  }

  private func weighted(_ weight: Font.Weight) -> Self {
    if let baseFont {
      return .font(baseFont.weight(weight))
    }
    return Self(
      baseFont: nil,
      pointSize: pointSize,
      weight: weight,
      design: design,
      isItalic: isItalic
    )
  }
}

struct HarnessMarkdownImageSettings {
  var maxInlineHeight: CGFloat
  var maxBlockHeight: CGFloat
  var cornerRadius: CGFloat

  static let `default` = Self(
    maxInlineHeight: 22,
    maxBlockHeight: 220,
    cornerRadius: 3
  )

  func scaled(by scale: CGFloat) -> Self {
    Self(
      maxInlineHeight: max(1, maxInlineHeight * scale),
      maxBlockHeight: max(1, maxBlockHeight * scale),
      cornerRadius: cornerRadius
    )
  }
}

struct HarnessMarkdownInlineRenderStyle {
  let font: Font
  let codeFont: Font
  let colors: HarnessMarkdownColorSettings

  func withFont(_ font: Font) -> Self {
    Self(font: font, codeFont: codeFont, colors: colors)
  }
}
