import SwiftUI

func monitorGlass(tint: Color? = nil, interactive: Bool = false) -> Glass {
  var glass = Glass.regular
  if let tint {
    glass = glass.tint(tint)
  }
  if interactive {
    glass = glass.interactive()
  }
  return glass
}

struct MonitorRoundedGlassBackground: View {
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
    shadowColor: Color = MonitorTheme.glassShadow,
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
    return colorScheme == .dark ? .black : .white
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    shape
      .fill(resolvedFillColor.opacity(fillOpacity))
      .overlay {
        shape
          .fill(.clear)
          .glassEffect(monitorGlass(tint: tint, interactive: interactive), in: shape)
      }
      .overlay {
        shape.stroke(strokeColor, lineWidth: 1)
      }
      .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
  }
}

struct MonitorCapsuleGlassBackground: View {
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
    shadowColor: Color = MonitorTheme.glassShadow.opacity(0.55),
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
    return colorScheme == .dark ? .black : .white
  }

  var body: some View {
    let shape = Capsule()

    shape
      .fill(resolvedFillColor.opacity(fillOpacity))
      .overlay {
        shape
          .fill(.clear)
          .glassEffect(monitorGlass(tint: tint, interactive: interactive), in: shape)
      }
      .overlay {
        shape.stroke(strokeColor, lineWidth: 1)
      }
      .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
  }
}

struct MonitorGlassContainer<Content: View>: View {
  let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    GlassEffectContainer(spacing: spacing) {
      content
    }
  }
}

struct MonitorInsetPanelBackground: View {
  let cornerRadius: CGFloat
  let fillOpacity: Double
  let strokeOpacity: Double

  var body: some View {
    let resolvedFillOpacity = max(fillOpacity, 0.06)
    let resolvedStrokeOpacity = max(strokeOpacity, 0.10)

    MonitorRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: MonitorTheme.surface,
      interactive: false,
      fillOpacity: max(resolvedFillOpacity, 0.08),
      strokeColor: Color.white.opacity(resolvedStrokeOpacity)
    )
  }
}

struct MonitorGlassCapsuleBackground: View {
  var body: some View {
    MonitorCapsuleGlassBackground(
      tint: MonitorTheme.surface,
      interactive: false,
      fillOpacity: 0.10,
      strokeColor: MonitorTheme.glassStroke,
      shadowColor: MonitorTheme.glassShadow.opacity(0.55),
      shadowRadius: 14,
      shadowY: 8
    )
  }
}

struct MonitorInteractiveCardBackground: View {
  let cornerRadius: CGFloat
  let tint: Color?

  var body: some View {
    let resolvedTint = tint ?? MonitorTheme.surface

    MonitorRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: resolvedTint,
      interactive: true,
      fillOpacity: tint == nil ? 0.12 : 0.16,
      strokeColor: tint?.opacity(0.32) ?? Color.white.opacity(0.10)
    )
  }
}
