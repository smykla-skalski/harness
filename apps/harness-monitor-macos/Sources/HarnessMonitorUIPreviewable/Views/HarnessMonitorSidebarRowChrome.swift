import SwiftUI

private struct SidebarRowButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color
  let isHovered: Bool
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fillOpacity = configuration.isPressed ? 0.14 : isHovered ? 0.09 : 0.04
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(tint.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? 1 : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct SidebarDisclosureButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fillOpacity = configuration.isPressed ? 0.12 : 0.0
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(tint.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? 1 : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct SidebarRowHoverModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        SidebarRowButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered
        )
      )
      .onContinuousHover { phase in
        withAnimation(.easeOut(duration: 0.15)) {
          switch phase {
          case .active:
            isHovered = true
          case .ended:
            isHovered = false
          }
        }
      }
  }
}

extension View {
  func harnessSidebarRowButtonStyle(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusLG,
    tint: Color = HarnessMonitorTheme.accent
  ) -> some View {
    modifier(SidebarRowHoverModifier(cornerRadius: cornerRadius, tint: tint))
  }

  func harnessSidebarDisclosureButtonStyle(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusLG,
    tint: Color = HarnessMonitorTheme.accent
  ) -> some View {
    buttonStyle(SidebarDisclosureButtonStyle(cornerRadius: cornerRadius, tint: tint))
  }
}
