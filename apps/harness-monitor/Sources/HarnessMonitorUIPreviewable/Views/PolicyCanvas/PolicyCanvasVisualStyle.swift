import AppKit
import SwiftUI

enum PolicyCanvasVisualStyle {
  static let rootBackground = Color(nsColor: .windowBackgroundColor)
  static let chromeBackground = Color(nsColor: .windowBackgroundColor)
  static let panelBackground = Color(nsColor: .underPageBackgroundColor)
  static let railBackground = Color(nsColor: .underPageBackgroundColor)
  static let canvasBackground = Color(nsColor: .textBackgroundColor)
  static let canvasGridDot = Color(nsColor: .separatorColor).opacity(0.35)

  static let surface = Color(nsColor: .controlBackgroundColor).opacity(0.72)
  static let elevatedSurface = Color(nsColor: .textBackgroundColor)
  static let controlSurface = Color(nsColor: .controlBackgroundColor).opacity(0.82)
  static let controlHoverSurface = Color(nsColor: .quaternaryLabelColor).opacity(0.18)
  static let fieldSurface = Color(nsColor: .textBackgroundColor)
  static let border = Color(nsColor: .separatorColor).opacity(0.72)
  static let subtleBorder = Color(nsColor: .separatorColor).opacity(0.48)
  static let separator = Color(nsColor: .separatorColor).opacity(0.6)

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
