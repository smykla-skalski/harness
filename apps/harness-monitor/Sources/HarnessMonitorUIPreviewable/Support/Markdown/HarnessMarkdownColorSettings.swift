import SwiftUI

struct HarnessMarkdownColorSettings {
  var text: Color
  var secondaryText: Color
  var link: Color
  var inlineCodeText: Color
  var inlineCodeBackground: Color
  var alertNote: Color
  var alertTip: Color
  var alertImportant: Color
  var alertWarning: Color
  var alertCaution: Color
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
    inlineCodeText: HarnessMonitorTheme.inlineCodeText,
    inlineCodeBackground: HarnessMonitorTheme.inlineCodeBackground,
    alertNote: HarnessMonitorTheme.accent,
    alertTip: HarnessMonitorTheme.success,
    alertImportant: HarnessMonitorTheme.warmAccent,
    alertWarning: HarnessMonitorTheme.caution,
    alertCaution: HarnessMonitorTheme.danger,
    quoteBar: HarnessMonitorTheme.controlBorder,
    tableBackground: HarnessMonitorTheme.ink.opacity(0.04),
    tableBorder: HarnessMonitorTheme.controlBorder.opacity(0.5),
    taskChecked: HarnessMonitorTheme.accent,
    taskUnchecked: HarnessMonitorTheme.secondaryInk,
    thematicBreak: HarnessMonitorTheme.controlBorder
  )

  static let selectedRow = Self(
    text: Color(nsColor: .alternateSelectedControlTextColor),
    secondaryText: Color(nsColor: .alternateSelectedControlTextColor),
    link: Color(nsColor: .alternateSelectedControlTextColor),
    inlineCodeText: Color(nsColor: .alternateSelectedControlTextColor),
    inlineCodeBackground: Color(nsColor: .alternateSelectedControlTextColor).opacity(0.16),
    alertNote: Color(nsColor: .alternateSelectedControlTextColor),
    alertTip: Color(nsColor: .alternateSelectedControlTextColor),
    alertImportant: Color(nsColor: .alternateSelectedControlTextColor),
    alertWarning: Color(nsColor: .alternateSelectedControlTextColor),
    alertCaution: Color(nsColor: .alternateSelectedControlTextColor),
    quoteBar: Color(nsColor: .alternateSelectedControlTextColor).opacity(0.32),
    tableBackground: Color(nsColor: .alternateSelectedControlTextColor).opacity(0.10),
    tableBorder: Color(nsColor: .alternateSelectedControlTextColor).opacity(0.32),
    taskChecked: Color(nsColor: .alternateSelectedControlTextColor),
    taskUnchecked: Color(nsColor: .alternateSelectedControlTextColor),
    thematicBreak: Color(nsColor: .alternateSelectedControlTextColor).opacity(0.32)
  )

  func alertAccent(for kind: HarnessMarkdownAlert.Kind) -> Color {
    switch kind {
    case .note:
      alertNote
    case .tip:
      alertTip
    case .important:
      alertImportant
    case .warning:
      alertWarning
    case .caution:
      alertCaution
    }
  }
}
