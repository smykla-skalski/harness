import SwiftUI

enum HarnessMonitorFloatingGlassProminence {
  case subdued
  case regular
}

struct HarnessMonitorGlassControlGroup<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content
  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if let spacing {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      GlassEffectContainer {
        content
      }
    }
  }
}

private struct HarnessMonitorFloatingGlassModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color
  let prominence: HarnessMonitorFloatingGlassProminence
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    if prominence == .subdued {
      if reduceTransparency {
        return colorSchemeContrast == .increased ? 0.26 : 0.18
      }
      return colorSchemeContrast == .increased ? 0.14 : 0.08
    }
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.42 : 0.32
    }
    return colorSchemeContrast == .increased ? 0.26 : 0.18
  }

  private var fallbackStrokeOpacity: Double {
    if prominence == .subdued {
      return colorSchemeContrast == .increased ? 0.28 : 0.16
    }
    return colorSchemeContrast == .increased ? 0.42 : 0.24
  }

  private var fallbackStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  private var glassTintOpacity: Double {
    if prominence == .subdued {
      return colorSchemeContrast == .increased ? 0.14 : 0.08
    }
    return colorSchemeContrast == .increased ? 0.24 : 0.16
  }

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if reduceTransparency {
      content
        .background {
          shape
            .fill(tint.opacity(fallbackFillOpacity))
        }
        .overlay {
          shape
            .strokeBorder(tint.opacity(fallbackStrokeOpacity), lineWidth: fallbackStrokeWidth)
        }
    } else {
      content
        .glassEffect(
          .regular.tint(tint.opacity(glassTintOpacity)),
          in: .rect(cornerRadius: cornerRadius, style: .continuous)
        )
    }
  }
}

extension View {
  func harnessFloatingControlGlass(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusSM,
    tint: Color = HarnessMonitorTheme.ink,
    prominence: HarnessMonitorFloatingGlassProminence = .regular
  ) -> some View {
    modifier(
      HarnessMonitorFloatingGlassModifier(
        cornerRadius: cornerRadius,
        tint: tint,
        prominence: prominence
      )
    )
  }
}

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
