import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

enum HarnessMonitorActionButtonVariant {
  case prominent
  case bordered
  case borderless
}

extension View {
  func harnessPlainButtonStyle() -> some View {
    buttonStyle(.borderless)
  }

  func harnessActionButtonStyle(
    variant: HarnessMonitorActionButtonVariant,
    tint: Color? = nil
  ) -> some View {
    modifier(
      HarnessMonitorActionButtonStyleModifier(
        variant: variant,
        tint: tint ?? HarnessMonitorTheme.accent
      )
    )
  }

  func harnessGlassButtonStyle() -> some View {
    buttonStyle(.glass)
  }

  func harnessGlassButtonStyle(controlSize: ControlSize) -> some View {
    buttonStyle(.glass).controlSize(controlSize)
  }
}

private struct HarnessMonitorActionButtonStyleModifier: ViewModifier {
  let variant: HarnessMonitorActionButtonVariant
  let tint: Color

  func body(content: Content) -> some View {
    switch variant {
    case .prominent:
      content
        .buttonStyle(.glassProminent)
        .tint(tint)
    case .bordered:
      content
        .buttonStyle(.glass)
        .tint(tint)
    case .borderless:
      content
        .buttonStyle(.borderless)
        .tint(tint)
    }
  }
}
