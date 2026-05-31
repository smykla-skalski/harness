import SwiftUI

private struct DashboardPolicyCanvasFooterTabChromeModifier: ViewModifier {
  let isSelected: Bool
  let isHovering: Bool
  let isPressed: Bool
  var showsLeadingSeparator = false
  var showsTrailingSeparator = true

  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.isEnabled)
  private var isEnabled

  private var borderWidth: CGFloat {
    colorSchemeContrast == .increased ? 2 : 1
  }

  private var selectedChromeColor: Color {
    guard isEnabled else {
      return .clear
    }
    return Color.accentColor.opacity(isPressed ? 0.22 : (isHovering ? 0.18 : 0.14))
  }

  private var separatorColor: Color {
    guard isEnabled else {
      return HarnessMonitorTheme.controlBorder.opacity(
        colorSchemeContrast == .increased ? 0.48 : 0.32
      )
    }
    if isSelected {
      return selectedChromeColor
    }
    return HarnessMonitorTheme.controlBorder.opacity(
      colorSchemeContrast == .increased ? 0.96 : 0.76
    )
  }

  private var backgroundColor: Color {
    guard isEnabled else {
      return .clear
    }
    if isSelected {
      return selectedChromeColor
    }
    if isHovering {
      return HarnessMonitorTheme.secondaryInk.opacity(isPressed ? 0.12 : 0.08)
    }
    if isPressed {
      return HarnessMonitorTheme.secondaryInk.opacity(0.06)
    }
    return .clear
  }

  func body(content: Content) -> some View {
    content
      .frame(maxHeight: .infinity, alignment: .leading)
      .background {
        Rectangle()
          .fill(backgroundColor)
      }
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(selectedChromeColor)
          .frame(width: showsLeadingSeparator ? borderWidth : 0)
          .opacity(showsLeadingSeparator ? 1 : 0)
      }
      .overlay(alignment: .trailing) {
        Rectangle()
          .fill(separatorColor)
          .frame(width: showsTrailingSeparator ? borderWidth : 0)
          .opacity(showsTrailingSeparator ? 1 : 0)
      }
      .contentShape(Rectangle())
      .opacity(isEnabled ? (isPressed ? 0.97 : 1) : 0.56)
  }
}

extension View {
  func dashboardPolicyCanvasFooterTabChrome(
    isSelected: Bool,
    isHovering: Bool,
    isPressed: Bool,
    showsLeadingSeparator: Bool = false,
    showsTrailingSeparator: Bool = true
  ) -> some View {
    modifier(
      DashboardPolicyCanvasFooterTabChromeModifier(
        isSelected: isSelected,
        isHovering: isHovering,
        isPressed: isPressed,
        showsLeadingSeparator: showsLeadingSeparator,
        showsTrailingSeparator: showsTrailingSeparator
      )
    )
  }
}
