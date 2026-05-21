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
    inlineCodeText: HarnessMonitorTheme.ink,
    inlineCodeBackground: HarnessMonitorTheme.accent.opacity(0.10),
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
