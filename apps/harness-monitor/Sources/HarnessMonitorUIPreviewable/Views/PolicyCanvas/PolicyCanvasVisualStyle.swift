import SwiftUI

enum PolicyCanvasVisualStyle {
  static let rootBackground = Color(red: 0.055, green: 0.062, blue: 0.078)
  static let chromeBackground = Color(red: 0.075, green: 0.083, blue: 0.105)
  static let panelBackground = Color(red: 0.072, green: 0.080, blue: 0.102)
  static let railBackground = Color(red: 0.060, green: 0.068, blue: 0.088)
  static let canvasBackground = Color(red: 0.034, green: 0.041, blue: 0.054)
  static let canvasGridDot = HarnessMonitorTheme.ink.opacity(0.055)

  static let surface = Color.white.opacity(0.045)
  static let elevatedSurface = Color(red: 0.095, green: 0.108, blue: 0.137)
  static let controlSurface = Color.white.opacity(0.050)
  static let controlHoverSurface = Color.white.opacity(0.082)
  static let fieldSurface = Color.white.opacity(0.055)
  static let border = Color.white.opacity(0.090)
  static let subtleBorder = Color.white.opacity(0.060)
  static let separator = Color.white.opacity(0.075)

  static let primaryText = HarnessMonitorTheme.ink
  static let secondaryText = HarnessMonitorTheme.secondaryInk
  static let tertiaryText = HarnessMonitorTheme.tertiaryInk

  static let activeTint = HarnessMonitorTheme.accent
  static let readyTint = HarnessMonitorTheme.success
  static let warningTint = HarnessMonitorTheme.caution
  static let blockedTint = HarnessMonitorTheme.danger

  static func nodeTint(for kind: PolicyCanvasNodeKind) -> Color {
    switch kind {
    case .source:
      HarnessMonitorTheme.accent
    case .condition:
      HarnessMonitorTheme.secondaryInk
    case .review:
      HarnessMonitorTheme.caution
    case .transform:
      HarnessMonitorTheme.warmAccent
    case .decision:
      HarnessMonitorTheme.success
    }
  }

  static func groupTint(for tone: PolicyCanvasGroupTone) -> Color {
    switch tone {
    case .intake:
      HarnessMonitorTheme.accent
    case .evaluation:
      HarnessMonitorTheme.warmAccent
    case .release:
      HarnessMonitorTheme.success
    }
  }

  static func edgeTint(for kind: PolicyCanvasEdgeKind) -> Color {
    switch kind {
    case .flow:
      HarnessMonitorTheme.accent
    case .control:
      HarnessMonitorTheme.caution
    case .error:
      HarnessMonitorTheme.danger
    }
  }
}
