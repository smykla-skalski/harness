import SwiftUI

func harnessGlass(tint: Color? = nil, interactive: Bool = false) -> Glass {
  var glass = Glass.regular
  if let tint {
    glass = glass.tint(tint)
  }
  if interactive {
    glass = glass.interactive()
  }
  return glass
}

struct HarnessRoundedGlassBackground: View {
  @Environment(\.colorScheme)
  private var colorScheme

  let cornerRadius: CGFloat
  let tint: Color?
  let interactive: Bool
  let fillColor: Color?
  let fillOpacity: Double
  let strokeColor: Color
  let shadowColor: Color
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  init(
    cornerRadius: CGFloat,
    tint: Color?,
    interactive: Bool,
    fillColor: Color? = nil,
    fillOpacity: Double = 0.18,
    strokeColor: Color,
    shadowColor: Color = HarnessTheme.glassShadow,
    shadowRadius: CGFloat = 18,
    shadowY: CGFloat = 12
  ) {
    self.cornerRadius = cornerRadius
    self.tint = tint
    self.interactive = interactive
    self.fillColor = fillColor
    self.fillOpacity = fillOpacity
    self.strokeColor = strokeColor
    self.shadowColor = shadowColor
    self.shadowRadius = shadowRadius
    self.shadowY = shadowY
  }

  private var resolvedFillColor: Color {
    if let fillColor {
      return fillColor
    }
    if let tint {
      return tint
    }
    return colorScheme == .dark ? HarnessTheme.panel : HarnessTheme.panel
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if HarnessTheme.usesGradientChrome {
      shape
        .fill(resolvedFillColor.opacity(fillOpacity))
        .overlay {
          shape
            .fill(.clear)
            .glassEffect(harnessGlass(tint: tint, interactive: interactive), in: shape)
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(resolvedFillColor)
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(
          color: shadowColor.opacity(0.65),
          radius: max(4, shadowRadius * 0.35),
          x: 0,
          y: max(2, shadowY * 0.25)
        )
    }
  }
}

struct HarnessCapsuleGlassBackground: View {
  @Environment(\.colorScheme)
  private var colorScheme

  let tint: Color?
  let interactive: Bool
  let fillColor: Color?
  let fillOpacity: Double
  let strokeColor: Color
  let shadowColor: Color
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  init(
    tint: Color?,
    interactive: Bool,
    fillColor: Color? = nil,
    fillOpacity: Double = 0.16,
    strokeColor: Color,
    shadowColor: Color = HarnessTheme.glassShadow.opacity(0.55),
    shadowRadius: CGFloat = 14,
    shadowY: CGFloat = 8
  ) {
    self.tint = tint
    self.interactive = interactive
    self.fillColor = fillColor
    self.fillOpacity = fillOpacity
    self.strokeColor = strokeColor
    self.shadowColor = shadowColor
    self.shadowRadius = shadowRadius
    self.shadowY = shadowY
  }

  private var resolvedFillColor: Color {
    if let fillColor {
      return fillColor
    }
    if let tint {
      return tint
    }
    return colorScheme == .dark ? HarnessTheme.surface : HarnessTheme.surface
  }

  var body: some View {
    let shape = Capsule()

    if HarnessTheme.usesGradientChrome {
      shape
        .fill(resolvedFillColor.opacity(fillOpacity))
        .overlay {
          shape
            .fill(.clear)
            .glassEffect(harnessGlass(tint: tint, interactive: interactive), in: shape)
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(resolvedFillColor)
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(
          color: shadowColor.opacity(0.55),
          radius: max(3, shadowRadius * 0.3),
          x: 0,
          y: max(1, shadowY * 0.2)
        )
    }
  }
}

struct HarnessGlassContainer<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if HarnessTheme.usesGradientChrome {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

struct HarnessInsetPanelBackground: View {
  let cornerRadius: CGFloat
  let fillOpacity: Double
  let strokeOpacity: Double

  var body: some View {
    let resolvedFillOpacity = max(fillOpacity, 0.06)
    let resolvedStrokeOpacity = max(strokeOpacity, 0.10)

    HarnessRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: HarnessTheme.surface,
      interactive: false,
      fillOpacity: max(resolvedFillOpacity, 0.08),
      strokeColor: Color.white.opacity(resolvedStrokeOpacity)
    )
  }
}

struct HarnessGlassCapsuleBackground: View {
  var body: some View {
    HarnessCapsuleGlassBackground(
      tint: HarnessTheme.surface,
      interactive: false,
      fillOpacity: 0.10,
      strokeColor: HarnessTheme.glassStroke,
      shadowColor: HarnessTheme.glassShadow.opacity(0.55),
      shadowRadius: 14,
      shadowY: 8
    )
  }
}

struct HarnessInteractiveCardBackground: View {
  let cornerRadius: CGFloat
  let tint: Color?

  var body: some View {
    let resolvedTint = tint ?? HarnessTheme.surface

    HarnessRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: resolvedTint,
      interactive: true,
      fillOpacity: tint == nil ? 0.12 : 0.16,
      strokeColor: tint?.opacity(0.32) ?? Color.white.opacity(0.10)
    )
  }
}
