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

private struct HarnessMonitorDragFeedbackSurfaceModifier<Surface: InsettableShape>: ViewModifier {
  let shape: Surface
  let tint: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.42 : 0.32
    }
    return colorSchemeContrast == .increased ? 0.26 : 0.18
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.46 : 0.28
  }

  private var strokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  func body(content: Content) -> some View {
    // SwiftUI drag previews are rendered through a snapshot path that rejects
    // Liquid Glass SDF output on macOS 26.
    content
      .background {
        shape.fill(tint.opacity(fillOpacity))
      }
      .overlay {
        shape.strokeBorder(tint.opacity(strokeOpacity), lineWidth: strokeWidth)
      }
  }
}

extension View {
  func harnessDragFeedbackSurface(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusSM,
    tint: Color = HarnessMonitorTheme.ink
  ) -> some View {
    modifier(
      HarnessMonitorDragFeedbackSurfaceModifier(
        shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
        tint: tint
      )
    )
  }

  func harnessDragFeedbackPillSurface(tint: Color = HarnessMonitorTheme.ink) -> some View {
    modifier(HarnessMonitorDragFeedbackSurfaceModifier(shape: Capsule(), tint: tint))
  }
}

// MARK: - Panel glass (non-interactive rectangle backgrounds)

private struct HarnessMonitorPanelGlassModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    reduceTransparency
      ? (colorSchemeContrast == .increased ? 0.32 : 0.22)
      : (colorSchemeContrast == .increased ? 0.18 : 0.12)
  }

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background {
          Rectangle().fill(HarnessMonitorTheme.ink.opacity(fallbackFillOpacity))
        }
    } else {
      content
        .glassEffect(.regular, in: .rect)
    }
  }
}

extension View {
  func harnessPanelGlass() -> some View {
    modifier(HarnessMonitorPanelGlassModifier())
  }
}

// MARK: - Toast dismiss circle glass

private struct HarnessMonitorToastDismissGlassModifier: ViewModifier {
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.24 : 0.16
    }
    return colorSchemeContrast == .increased ? 0.12 : 0.08
  }

  private var fallbackStrokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.28 : 0.18
  }

  private var glassTintOpacity: Double {
    colorSchemeContrast == .increased ? 0.16 : 0.1
  }

  func body(content: Content) -> some View {
    if reduceTransparency {
      content
        .background {
          Circle().fill(HarnessMonitorTheme.ink.opacity(fallbackFillOpacity))
        }
        .overlay {
          Circle()
            .strokeBorder(
              HarnessMonitorTheme.ink.opacity(fallbackStrokeOpacity),
              lineWidth: colorSchemeContrast == .increased ? 1.5 : 1
            )
        }
    } else {
      content
        .glassEffect(
          .regular.tint(HarnessMonitorTheme.ink.opacity(glassTintOpacity)).interactive(),
          in: .circle
        )
    }
  }
}

extension View {
  func harnessToastDismissGlass() -> some View {
    modifier(HarnessMonitorToastDismissGlassModifier())
  }
}

// MARK: - Feedback toast surface glass (severity-tinted)

private struct HarnessMonitorFeedbackToastGlassModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var fallbackFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.72 : 0.6
    }
    return colorSchemeContrast == .increased ? 0.55 : 0.42
  }

  private var fallbackStrokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.85 : 0.65
  }

  private var fallbackStrokeWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.5 : 1
  }

  private var glassTintOpacity: Double {
    colorSchemeContrast == .increased ? 0.62 : 0.48
  }

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    if reduceTransparency {
      content
        .background {
          shape.fill(tint.opacity(fallbackFillOpacity))
        }
        .overlay {
          shape.strokeBorder(tint.opacity(fallbackStrokeOpacity), lineWidth: fallbackStrokeWidth)
        }
    } else {
      content
        .glassEffect(
          .regular.tint(tint.opacity(glassTintOpacity)),
          in: .rect(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
          shape.strokeBorder(tint.opacity(0.45), lineWidth: 1)
        }
    }
  }
}

extension View {
  func harnessFeedbackToastGlass(
    cornerRadius: CGFloat = HarnessMonitorTheme.cornerRadiusLG,
    tint: Color
  ) -> some View {
    modifier(
      HarnessMonitorFeedbackToastGlassModifier(
        cornerRadius: cornerRadius,
        tint: tint
      )
    )
  }
}
