import SwiftUI
import HarnessMonitorPolicyCanvasAlgorithms

private struct HarnessMonitorControlPillGlassModifier: ViewModifier {
  let tint: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.4 : 0.3
    }
    return colorSchemeContrast == .increased ? 0.26 : 0.16
  }

  private var fallbackStrokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.42 : 0.24
  }

  private var fallbackStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background {
          Capsule()
            .fill(tint.opacity(fallbackFillOpacity))
        }
        .overlay {
          Capsule()
            .strokeBorder(tint.opacity(fallbackStrokeOpacity), lineWidth: fallbackStrokeWidth)
        }
    } else {
      content
        .glassEffect(
          .regular.tint(tint.opacity(colorSchemeContrast == .increased ? 0.24 : 0.16)),
          in: .capsule
        )
    }
  }
}

extension View {
  func harnessControlPillGlass(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorControlPillGlassModifier(tint: tint))
  }
}
