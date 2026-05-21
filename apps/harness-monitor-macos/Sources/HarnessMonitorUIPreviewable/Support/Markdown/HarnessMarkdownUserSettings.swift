import SwiftUI

enum HarnessMarkdownScalePreference: String, CaseIterable, Codable, Identifiable {
  case appTextSize
  case custom
  case fixed

  var id: String { rawValue }

  var label: String {
    switch self {
    case .appTextSize: "App text size"
    case .custom: "Custom scale"
    case .fixed: "Fixed 100%"
    }
  }

  func scaleMode(customScale: Double) -> HarnessMarkdownFontScaleMode {
    switch self {
    case .appTextSize: .environment
    case .custom: .explicit(CGFloat(max(0.5, min(customScale, 2))))
    case .fixed: .fixed
    }
  }
}

enum HarnessMarkdownColorChoice: String, CaseIterable, Codable, Identifiable {
  case primary
  case secondary
  case tertiary
  case accent
  case success
  case caution
  case danger
  case warmAccent
  case border
  case subtleFill
  case accentFill
  case clear

  var id: String { rawValue }

  var label: String {
    switch self {
    case .primary: "Primary"
    case .secondary: "Secondary"
    case .tertiary: "Tertiary"
    case .accent: "Accent"
    case .success: "Success"
    case .caution: "Caution"
    case .danger: "Danger"
    case .warmAccent: "Warm accent"
    case .border: "Border"
    case .subtleFill: "Subtle fill"
    case .accentFill: "Accent fill"
    case .clear: "Clear"
    }
  }

  var color: Color {
    switch self {
    case .primary: HarnessMonitorTheme.ink
    case .secondary: HarnessMonitorTheme.secondaryInk
    case .tertiary: HarnessMonitorTheme.tertiaryInk
    case .accent: HarnessMonitorTheme.accent
    case .success: HarnessMonitorTheme.success
    case .caution: HarnessMonitorTheme.caution
    case .danger: HarnessMonitorTheme.danger
    case .warmAccent: HarnessMonitorTheme.warmAccent
    case .border: HarnessMonitorTheme.controlBorder
    case .subtleFill: HarnessMonitorTheme.ink.opacity(0.04)
    case .accentFill: HarnessMonitorTheme.accent.opacity(0.10)
    case .clear: Color.clear
    }
  }
}

struct HarnessMarkdownUserSettings: Codable, Equatable {
  static let storageKey = "harness.monitor.markdown.render-settings"

  var scale = Scale()
  var typography = Typography()
  var spacing = Spacing()
  var colors = Colors()
  var code = Code()
  var images = Images()

  static let `default` = Self()
  static let defaultStorageValue = Self.default.storageValue

  static func decode(_ value: String) -> Self {
    guard let data = value.data(using: .utf8),
      let decoded = try? JSONDecoder().decode(Self.self, from: data)
    else { return .default }
    return decoded
  }

  var storageValue: String {
    guard let data = try? JSONEncoder().encode(self),
      let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
  }

  var renderSettings: HarnessMarkdownRenderSettings {
    let scaleMode = scale.mode.scaleMode(customScale: scale.customScale)
    return HarnessMarkdownRenderSettings.sized(
      body: typography.bodySize,
      inlineCode: typography.inlineCodeSize,
      heading1: typography.heading1Size,
      heading2: typography.heading2Size,
      heading3: typography.heading3Size,
      headingDefault: typography.headingDefaultSize,
      fontScaleMode: scaleMode,
      colors: colors.markdownColors,
      codeBlock: code.renderSettings(typography: typography, fontScaleMode: scaleMode),
      images: images.settings,
      spacing: spacing.settings
    )
  }
}

struct HarnessMarkdownStoredRenderSettings: DynamicProperty {
  @AppStorage(HarnessMarkdownUserSettings.storageKey)
  private var storage = HarnessMarkdownUserSettings.defaultStorageValue

  var settings: HarnessMarkdownRenderSettings {
    HarnessMarkdownUserSettings.decode(storage).renderSettings
  }
}

extension HarnessMarkdownUserSettings {
  struct Scale: Codable, Equatable {
    var mode = HarnessMarkdownScalePreference.appTextSize
    var customScale = 1.0
  }

  struct Typography: Codable, Equatable {
    var bodySize = 13.0
    var inlineCodeSize = 12.0
    var heading1Size = 20.0
    var heading2Size = 17.0
    var heading3Size = 15.0
    var headingDefaultSize = 13.0
    var codeSize = 12.0
    var codeLabelSize = 11.0
    var codeErrorSize = 12.0
  }

  struct Images: Codable, Equatable {
    var maxInlineHeight = 22.0
    var maxBlockHeight = 220.0
    var cornerRadius = 3.0

    var settings: HarnessMarkdownImageSettings {
      HarnessMarkdownImageSettings(
        maxInlineHeight: CGFloat(max(1, maxInlineHeight)),
        maxBlockHeight: CGFloat(max(1, maxBlockHeight)),
        cornerRadius: CGFloat(max(0, cornerRadius))
      )
    }
  }
}

extension HarnessMarkdownUserSettings {
  struct Spacing: Codable, Equatable {
    var documentBlock = 8.0
    var paragraphBefore = 0.0
    var paragraphAfter = 0.0
    var headingBefore = 16.0
    var headingAfter = 8.0
    var blockQuoteBefore = 0.0
    var blockQuoteAfter = 0.0
    var codeBlockBefore = 0.0
    var codeBlockAfter = 0.0
    var detailsBefore = 0.0
    var detailsAfter = 0.0
    var listBefore = 0.0
    var listAfter = 0.0
    var tableBefore = 0.0
    var tableAfter = 0.0
    var thematicBreakBefore = 0.0
    var thematicBreakAfter = 0.0
    var nestedBlock = 4.0
    var detailsContentIndent = 8.0
    var detailsMaxHeight = 420.0
    var listItem = 4.0
    var listItemContent = 4.0
    var listMarkerGap = 6.0
    var listSymbolWidth = 6.0
    var listMarkerWidth = 20.0
    var quoteContentGap = 8.0
    var tableColumn = 12.0
    var tableRow = 4.0

    private enum CodingKeys: String, CodingKey {
      case documentBlock
      case paragraphBefore
      case paragraphAfter
      case headingBefore
      case headingAfter
      case blockQuoteBefore
      case blockQuoteAfter
      case codeBlockBefore
      case codeBlockAfter
      case detailsBefore
      case detailsAfter
      case listBefore
      case listAfter
      case tableBefore
      case tableAfter
      case thematicBreakBefore
      case thematicBreakAfter
      case nestedBlock
      case detailsContentIndent
      case detailsMaxHeight
      case listItem
      case listItemContent
      case listMarkerGap
      case listSymbolWidth
      case listMarkerWidth
      case quoteContentGap
      case tableColumn
      case tableRow
    }

    var settings: HarnessMarkdownSpacingSettings {
      HarnessMarkdownSpacingSettings(
        documentBlock: CGFloat(max(0, documentBlock)),
        paragraph: blockSpacing(before: paragraphBefore, after: paragraphAfter),
        heading: blockSpacing(before: headingBefore, after: headingAfter),
        blockQuote: blockSpacing(before: blockQuoteBefore, after: blockQuoteAfter),
        codeBlock: blockSpacing(before: codeBlockBefore, after: codeBlockAfter),
        details: blockSpacing(before: detailsBefore, after: detailsAfter),
        list: blockSpacing(before: listBefore, after: listAfter),
        table: blockSpacing(before: tableBefore, after: tableAfter),
        thematicBreak: blockSpacing(before: thematicBreakBefore, after: thematicBreakAfter),
        nestedBlock: CGFloat(max(0, nestedBlock)),
        detailsContentIndent: CGFloat(max(0, detailsContentIndent)),
        detailsMaxHeight: CGFloat(max(120, detailsMaxHeight)),
        listItem: CGFloat(max(0, listItem)),
        listItemContent: CGFloat(max(0, listItemContent)),
        listMarkerGap: CGFloat(max(0, listMarkerGap)),
        listSymbolWidth: CGFloat(max(0, listSymbolWidth)),
        listMarkerWidth: CGFloat(max(0, listMarkerWidth)),
        quoteContentGap: CGFloat(max(0, quoteContentGap)),
        tableColumn: CGFloat(max(0, tableColumn)),
        tableRow: CGFloat(max(0, tableRow))
      )
    }

    private func blockSpacing(before: Double, after: Double) -> HarnessMarkdownBlockSpacing {
      HarnessMarkdownBlockSpacing(before: CGFloat(max(0, before)), after: CGFloat(max(0, after)))
    }

    init() {}

    init(from decoder: Decoder) throws {
      self.init()
      let values = try decoder.container(keyedBy: CodingKeys.self)
      documentBlock =
        try values.decodeIfPresent(Double.self, forKey: .documentBlock) ?? documentBlock
      paragraphBefore =
        try values.decodeIfPresent(Double.self, forKey: .paragraphBefore) ?? paragraphBefore
      paragraphAfter =
        try values.decodeIfPresent(Double.self, forKey: .paragraphAfter) ?? paragraphAfter
      headingBefore =
        try values.decodeIfPresent(Double.self, forKey: .headingBefore) ?? headingBefore
      headingAfter = try values.decodeIfPresent(Double.self, forKey: .headingAfter) ?? headingAfter
      blockQuoteBefore =
        try values.decodeIfPresent(Double.self, forKey: .blockQuoteBefore) ?? blockQuoteBefore
      blockQuoteAfter =
        try values.decodeIfPresent(Double.self, forKey: .blockQuoteAfter) ?? blockQuoteAfter
      codeBlockBefore =
        try values.decodeIfPresent(Double.self, forKey: .codeBlockBefore) ?? codeBlockBefore
      codeBlockAfter =
        try values.decodeIfPresent(Double.self, forKey: .codeBlockAfter) ?? codeBlockAfter
      detailsBefore =
        try values.decodeIfPresent(Double.self, forKey: .detailsBefore) ?? detailsBefore
      detailsAfter = try values.decodeIfPresent(Double.self, forKey: .detailsAfter) ?? detailsAfter
      listBefore = try values.decodeIfPresent(Double.self, forKey: .listBefore) ?? listBefore
      listAfter = try values.decodeIfPresent(Double.self, forKey: .listAfter) ?? listAfter
      tableBefore = try values.decodeIfPresent(Double.self, forKey: .tableBefore) ?? tableBefore
      tableAfter = try values.decodeIfPresent(Double.self, forKey: .tableAfter) ?? tableAfter
      thematicBreakBefore =
        try values.decodeIfPresent(Double.self, forKey: .thematicBreakBefore) ?? thematicBreakBefore
      thematicBreakAfter =
        try values.decodeIfPresent(Double.self, forKey: .thematicBreakAfter) ?? thematicBreakAfter
      nestedBlock = try values.decodeIfPresent(Double.self, forKey: .nestedBlock) ?? nestedBlock
      detailsContentIndent =
        try values.decodeIfPresent(Double.self, forKey: .detailsContentIndent)
        ?? detailsContentIndent
      detailsMaxHeight =
        try values.decodeIfPresent(Double.self, forKey: .detailsMaxHeight) ?? detailsMaxHeight
      listItem = try values.decodeIfPresent(Double.self, forKey: .listItem) ?? listItem
      listItemContent =
        try values.decodeIfPresent(Double.self, forKey: .listItemContent) ?? listItemContent
      listMarkerGap =
        try values.decodeIfPresent(Double.self, forKey: .listMarkerGap) ?? listMarkerGap
      listSymbolWidth =
        try values.decodeIfPresent(Double.self, forKey: .listSymbolWidth) ?? listSymbolWidth
      listMarkerWidth =
        try values.decodeIfPresent(Double.self, forKey: .listMarkerWidth) ?? listMarkerWidth
      quoteContentGap =
        try values.decodeIfPresent(Double.self, forKey: .quoteContentGap) ?? quoteContentGap
      tableColumn = try values.decodeIfPresent(Double.self, forKey: .tableColumn) ?? tableColumn
      tableRow = try values.decodeIfPresent(Double.self, forKey: .tableRow) ?? tableRow
    }
  }
}

extension HarnessMarkdownUserSettings {
  struct Colors: Codable, Equatable {
    var text = HarnessMarkdownColorChoice.primary
    var secondaryText = HarnessMarkdownColorChoice.secondary
    var link = HarnessMarkdownColorChoice.accent
    var inlineCodeText = HarnessMarkdownColorChoice.primary
    var inlineCodeBackground = HarnessMarkdownColorChoice.accentFill
    var quoteBar = HarnessMarkdownColorChoice.border
    var tableBackground = HarnessMarkdownColorChoice.subtleFill
    var tableBorder = HarnessMarkdownColorChoice.border
    var taskChecked = HarnessMarkdownColorChoice.accent
    var taskUnchecked = HarnessMarkdownColorChoice.secondary
    var thematicBreak = HarnessMarkdownColorChoice.border

    var markdownColors: HarnessMarkdownColorSettings {
      HarnessMarkdownColorSettings(
        text: text.color,
        secondaryText: secondaryText.color,
        link: link.color,
        inlineCodeText: inlineCodeText.color,
        inlineCodeBackground: inlineCodeBackground.color,
        quoteBar: quoteBar.color,
        tableBackground: tableBackground.color,
        tableBorder: tableBorder.color,
        taskChecked: taskChecked.color,
        taskUnchecked: taskUnchecked.color,
        thematicBreak: thematicBreak.color
      )
    }
  }
}

extension HarnessMarkdownUserSettings {
  struct Code: Codable, Equatable {
    var label = HarnessMarkdownColorChoice.secondary
    var error = HarnessMarkdownColorChoice.danger
    var background = HarnessMarkdownColorChoice.primary
    var border = HarnessMarkdownColorChoice.border
    var tokens = Tokens()

    func renderSettings(
      typography: HarnessMarkdownUserSettings.Typography,
      fontScaleMode: HarnessMarkdownFontScaleMode
    ) -> HarnessCodeBlockRenderSettings {
      HarnessCodeBlockRenderSettings(
        typography: HarnessCodeBlockTypography(
          code: .system(size: typography.codeSize, design: .monospaced),
          label: .system(size: typography.codeLabelSize, weight: .semibold),
          error: .system(size: typography.codeErrorSize, weight: .semibold)
        ),
        colors: HarnessCodeBlockColorSettings(
          label: label.color,
          error: error.color,
          background: background.color,
          border: border.color,
          tokens: tokens.colors
        ),
        fontScaleMode: fontScaleMode
      )
    }
  }

  struct Tokens: Codable, Equatable {
    var comment = HarnessMarkdownColorChoice.secondary
    var deleted = HarnessMarkdownColorChoice.danger
    var heading = HarnessMarkdownColorChoice.accent
    var inserted = HarnessMarkdownColorChoice.success
    var keyword = HarnessMarkdownColorChoice.accent
    var literal = HarnessMarkdownColorChoice.caution
    var number = HarnessMarkdownColorChoice.warmAccent
    var operatorSymbol = HarnessMarkdownColorChoice.tertiary
    var plain = HarnessMarkdownColorChoice.primary
    var property = HarnessMarkdownColorChoice.accent
    var punctuation = HarnessMarkdownColorChoice.tertiary
    var string = HarnessMarkdownColorChoice.success
    var type = HarnessMarkdownColorChoice.warmAccent
    var whitespace = HarnessMarkdownColorChoice.tertiary

    var colors: HarnessCodeTokenColors {
      HarnessCodeTokenColors(
        comment: comment.color,
        deleted: deleted.color,
        heading: heading.color,
        inserted: inserted.color,
        keyword: keyword.color,
        literal: literal.color,
        number: number.color,
        operatorSymbol: operatorSymbol.color,
        plain: plain.color,
        property: property.color,
        punctuation: punctuation.color,
        string: string.color,
        type: type.color,
        whitespace: whitespace.color
      )
    }
  }
}
