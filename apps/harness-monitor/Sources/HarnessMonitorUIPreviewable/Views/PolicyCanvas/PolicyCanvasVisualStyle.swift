import AppKit
import SwiftUI

enum PolicyCanvasVisualStyle {
  static let floatingControlMinHeight: CGFloat = 32
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
  private static let shadow = Color(nsColor: .shadowColor)

  static func nodeShadow(for colorScheme: ColorScheme) -> Color {
    shadow.opacity(colorScheme == .dark ? 0.26 : 0.14)
  }

  static func floatingControlBackground(_ colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? elevatedSurface.opacity(0.92) : Color(nsColor: .controlBackgroundColor)
  }

  static func floatingControlBorder(_ colorScheme: ColorScheme) -> Color {
    switch colorScheme {
    case .dark:
      border
    case .light:
      Color(nsColor: .separatorColor).opacity(0.9)
    @unknown default:
      Color(nsColor: .separatorColor).opacity(0.9)
    }
  }

  static func groupFill(
    _ tone: PolicyCanvasGroupTone,
    colorScheme: ColorScheme,
    isHighlighted: Bool,
    isFlashing: Bool
  ) -> Color {
    let opacity: Double
    switch (colorScheme, isFlashing, isHighlighted) {
    case (_, true, _):
      opacity = 0.18
    case (.dark, false, true):
      opacity = 0.12
    case (.dark, false, false):
      opacity = 0.045
    case (.light, false, true):
      opacity = 0.14
    case (.light, false, false):
      opacity = 0.075
    @unknown default:
      opacity = isHighlighted ? 0.14 : 0.075
    }
    return groupTint(for: tone).opacity(opacity)
  }

  static func groupStroke(
    _ tone: PolicyCanvasGroupTone,
    colorScheme: ColorScheme,
    isSelected: Bool,
    isHighlighted: Bool,
    isFlashing: Bool
  ) -> Color {
    let opacity: Double
    switch (colorScheme, isFlashing, isSelected || isHighlighted) {
    case (_, true, _):
      opacity = 0.68
    case (.dark, false, true):
      opacity = 0.52
    case (.dark, false, false):
      opacity = 0.22
    case (.light, false, true):
      opacity = 0.44
    case (.light, false, false):
      opacity = 0.30
    @unknown default:
      opacity = isSelected || isHighlighted ? 0.44 : 0.30
    }
    return groupTint(for: tone).opacity(opacity)
  }

  static func nodeStroke(
    _ kind: PolicyCanvasNodeKind,
    colorScheme: ColorScheme,
    isSelected: Bool,
    severity: PolicyCanvasIssueSeverity?,
    isFocused: Bool
  ) -> Color {
    if isFocused {
      return Color(nsColor: .keyboardFocusIndicatorColor)
    }
    if let severity {
      let opacity: Double
      switch colorScheme {
      case .dark:
        opacity = isSelected ? 0.98 : 0.82
      case .light:
        opacity = isSelected ? 0.92 : 0.74
      @unknown default:
        opacity = isSelected ? 0.92 : 0.74
      }
      return severity.accentColor.opacity(opacity)
    }
    return isSelected
      ? kind.accentColor.opacity(colorScheme == .dark ? 0.62 : 0.46)
      : border
  }

  static func groupTitleBackground(
    _ tone: PolicyCanvasGroupTone,
    colorScheme: ColorScheme
  ) -> Color {
    colorScheme == .dark ? elevatedSurface.opacity(0.84) : controlSurface
  }

  static func edgeLabelBackground(
    _ kind: PolicyCanvasEdgeKind,
    colorScheme: ColorScheme
  ) -> Color {
    colorScheme == .dark ? elevatedSurface.opacity(0.84) : controlSurface
  }

  static func edgeStrokeOpacity(_ colorScheme: ColorScheme, isSelected: Bool) -> Double {
    switch colorScheme {
    case .dark:
      isSelected ? 0.88 : 0.56
    case .light:
      isSelected ? 0.92 : 0.68
    @unknown default:
      isSelected ? 0.92 : 0.68
    }
  }

  static func edgeArrowOpacity(_ colorScheme: ColorScheme, isSelected: Bool) -> Double {
    switch colorScheme {
    case .dark:
      isSelected ? 0.96 : 0.76
    case .light:
      isSelected ? 0.98 : 0.86
    @unknown default:
      isSelected ? 0.98 : 0.86
    }
  }

  static func minimapBackground(_ colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? elevatedSurface.opacity(0.92) : controlSurface
  }

  static func minimapNodeFill(_ colorScheme: ColorScheme) -> Color {
    primaryText.opacity(colorScheme == .dark ? 0.72 : 0.58)
  }

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
