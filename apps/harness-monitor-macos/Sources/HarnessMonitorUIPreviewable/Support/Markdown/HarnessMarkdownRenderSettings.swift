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

struct HarnessMarkdownColorSettings {
  var text: Color
  var secondaryText: Color
  var link: Color
  var inlineCodeText: Color
  var inlineCodeBackground: Color
  var quoteBar: Color
  var tableBackground: Color
  var tableBorder: Color
  var taskChecked: Color
  var taskUnchecked: Color
  var thematicBreak: Color

  static let `default` = Self(
    text: HarnessMonitorTheme.ink,
    secondaryText: HarnessMonitorTheme.secondaryInk,
    link: HarnessMonitorTheme.accent,
    inlineCodeText: HarnessMonitorTheme.ink,
    inlineCodeBackground: HarnessMonitorTheme.accent.opacity(0.10),
    quoteBar: HarnessMonitorTheme.controlBorder,
    tableBackground: HarnessMonitorTheme.ink.opacity(0.04),
    tableBorder: HarnessMonitorTheme.controlBorder.opacity(0.5),
    taskChecked: HarnessMonitorTheme.accent,
    taskUnchecked: HarnessMonitorTheme.secondaryInk,
    thematicBreak: HarnessMonitorTheme.controlBorder
  )
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

struct HarnessMarkdownBlockSpacing: Equatable {
  var before: CGFloat
  var after: CGFloat

  static let none = Self(before: 0, after: 0)

  func scaled(by scale: CGFloat) -> Self {
    Self(before: max(0, before * scale), after: max(0, after * scale))
  }
}

struct HarnessMarkdownSpacingSettings: Equatable {
  var documentBlock: CGFloat
  var paragraph: HarnessMarkdownBlockSpacing
  var heading: HarnessMarkdownBlockSpacing
  var blockQuote: HarnessMarkdownBlockSpacing
  var codeBlock: HarnessMarkdownBlockSpacing
  var details: HarnessMarkdownBlockSpacing
  var list: HarnessMarkdownBlockSpacing
  var table: HarnessMarkdownBlockSpacing
  var thematicBreak: HarnessMarkdownBlockSpacing
  var nestedBlock: CGFloat
  var detailsContentIndent: CGFloat
  var listItem: CGFloat
  var listItemContent: CGFloat
  var listMarkerGap: CGFloat
  var listSymbolWidth: CGFloat
  var listMarkerWidth: CGFloat
  var quoteContentGap: CGFloat
  var tableColumn: CGFloat
  var tableRow: CGFloat

  static let `default` = Self(
    documentBlock: HarnessMonitorTheme.spacingSM,
    paragraph: .none,
    heading: HarnessMarkdownBlockSpacing(before: 16, after: 8),
    blockQuote: .none,
    codeBlock: .none,
    details: .none,
    list: .none,
    table: .none,
    thematicBreak: .none,
    nestedBlock: HarnessMonitorTheme.spacingXS,
    detailsContentIndent: HarnessMonitorTheme.spacingSM,
    listItem: HarnessMonitorTheme.spacingXS,
    listItemContent: HarnessMonitorTheme.spacingXS,
    listMarkerGap: 6,
    listSymbolWidth: 6,
    listMarkerWidth: 20,
    quoteContentGap: HarnessMonitorTheme.spacingSM,
    tableColumn: HarnessMonitorTheme.spacingMD,
    tableRow: HarnessMonitorTheme.spacingXS
  )

  func scaled(by scale: CGFloat) -> Self {
    Self(
      documentBlock: scaled(documentBlock, by: scale),
      paragraph: paragraph.scaled(by: scale),
      heading: heading.scaled(by: scale),
      blockQuote: blockQuote.scaled(by: scale),
      codeBlock: codeBlock.scaled(by: scale),
      details: details.scaled(by: scale),
      list: list.scaled(by: scale),
      table: table.scaled(by: scale),
      thematicBreak: thematicBreak.scaled(by: scale),
      nestedBlock: scaled(nestedBlock, by: scale),
      detailsContentIndent: scaled(detailsContentIndent, by: scale),
      listItem: scaled(listItem, by: scale),
      listItemContent: scaled(listItemContent, by: scale),
      listMarkerGap: scaled(listMarkerGap, by: scale),
      listSymbolWidth: scaled(listSymbolWidth, by: scale),
      listMarkerWidth: scaled(listMarkerWidth, by: scale),
      quoteContentGap: scaled(quoteContentGap, by: scale),
      tableColumn: scaled(tableColumn, by: scale),
      tableRow: scaled(tableRow, by: scale)
    )
  }

  func blockSpacing(for block: HarnessMarkdownBlock) -> HarnessMarkdownBlockSpacing {
    switch block {
    case .blockQuote:
      blockQuote
    case .codeBlock:
      codeBlock
    case .details:
      details
    case .heading:
      heading
    case .html, .paragraph:
      paragraph
    case .orderedList, .unorderedList:
      list
    case .table:
      table
    case .thematicBreak:
      thematicBreak
    }
  }

  private func scaled(_ value: CGFloat, by scale: CGFloat) -> CGFloat {
    max(0, value * scale)
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
