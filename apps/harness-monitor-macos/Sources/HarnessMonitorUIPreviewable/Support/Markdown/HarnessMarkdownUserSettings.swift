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
  struct Colors: Codable, Equatable {
    var text = HarnessMarkdownColorChoice.primary
    var secondaryText = HarnessMarkdownColorChoice.secondary
    var link = HarnessMarkdownColorChoice.accent
    var inlineCodeText = HarnessMarkdownColorChoice.primary
    var inlineCodeBackground = HarnessMarkdownColorChoice.accentFill
    var alertNote = HarnessMarkdownColorChoice.accent
    var alertTip = HarnessMarkdownColorChoice.success
    var alertImportant = HarnessMarkdownColorChoice.warmAccent
    var alertWarning = HarnessMarkdownColorChoice.caution
    var alertCaution = HarnessMarkdownColorChoice.danger
    var quoteBar = HarnessMarkdownColorChoice.border
    var tableBackground = HarnessMarkdownColorChoice.subtleFill
    var tableBorder = HarnessMarkdownColorChoice.border
    var taskChecked = HarnessMarkdownColorChoice.accent
    var taskUnchecked = HarnessMarkdownColorChoice.secondary
    var thematicBreak = HarnessMarkdownColorChoice.border

    enum CodingKeys: String, CodingKey {
      case text
      case secondaryText
      case link
      case inlineCodeText
      case inlineCodeBackground
      case alertNote
      case alertTip
      case alertImportant
      case alertWarning
      case alertCaution
      case quoteBar
      case tableBackground
      case tableBorder
      case taskChecked
      case taskUnchecked
      case thematicBreak
    }

    init() {}

    init(from decoder: Decoder) throws {
      self.init()
      let values = try decoder.container(keyedBy: CodingKeys.self)
      text = try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .text) ?? text
      secondaryText =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .secondaryText)
        ?? secondaryText
      link = try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .link) ?? link
      inlineCodeText =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .inlineCodeText)
        ?? inlineCodeText
      inlineCodeBackground =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .inlineCodeBackground)
        ?? inlineCodeBackground
      alertNote =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .alertNote)
        ?? alertNote
      alertTip =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .alertTip)
        ?? alertTip
      alertImportant =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .alertImportant)
        ?? alertImportant
      alertWarning =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .alertWarning)
        ?? alertWarning
      alertCaution =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .alertCaution)
        ?? alertCaution
      quoteBar =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .quoteBar) ?? quoteBar
      tableBackground =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .tableBackground)
        ?? tableBackground
      tableBorder =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .tableBorder)
        ?? tableBorder
      taskChecked =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .taskChecked)
        ?? taskChecked
      taskUnchecked =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .taskUnchecked)
        ?? taskUnchecked
      thematicBreak =
        try values.decodeIfPresent(HarnessMarkdownColorChoice.self, forKey: .thematicBreak)
        ?? thematicBreak
    }

    var markdownColors: HarnessMarkdownColorSettings {
      HarnessMarkdownColorSettings(
        text: text.color,
        secondaryText: secondaryText.color,
        link: link.color,
        inlineCodeText: inlineCodeText.color,
        inlineCodeBackground: inlineCodeBackground.color,
        alertNote: alertNote.color,
        alertTip: alertTip.color,
        alertImportant: alertImportant.color,
        alertWarning: alertWarning.color,
        alertCaution: alertCaution.color,
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
