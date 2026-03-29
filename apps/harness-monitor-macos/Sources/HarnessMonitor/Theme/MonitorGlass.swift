import SwiftUI

@available(macOS 26, *)
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
  let cornerRadius: CGFloat
  let tint: Color?
  let interactive: Bool
  let fallbackMaterial: Material
  let fallbackOverlay: Color
  let strokeColor: Color
  let shadowColor: Color
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  init(
    cornerRadius: CGFloat,
    tint: Color?,
    interactive: Bool,
    fallbackMaterial: Material,
    fallbackOverlay: Color,
    strokeColor: Color,
    shadowColor: Color = MonitorTheme.glassShadow,
    shadowRadius: CGFloat = 18,
    shadowY: CGFloat = 12
  ) {
    self.cornerRadius = cornerRadius
    self.tint = tint
    self.interactive = interactive
    self.fallbackMaterial = fallbackMaterial
    self.fallbackOverlay = fallbackOverlay
    self.strokeColor = strokeColor
    self.shadowColor = shadowColor
    self.shadowRadius = shadowRadius
    self.shadowY = shadowY
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if #available(macOS 26, *) {
      shape
        .fill(.clear)
        .glassEffect(monitorGlass(tint: tint, interactive: interactive), in: shape)
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(fallbackMaterial)
        .overlay {
          shape.fill(fallbackOverlay)
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    }
  }
}

struct MonitorCapsuleGlassBackground: View {
  let tint: Color?
  let interactive: Bool
  let fallbackMaterial: Material
  let fallbackOverlay: Color
  let strokeColor: Color
  let shadowColor: Color
  let shadowRadius: CGFloat
  let shadowY: CGFloat

  init(
    tint: Color?,
    interactive: Bool,
    fallbackMaterial: Material,
    fallbackOverlay: Color,
    strokeColor: Color,
    shadowColor: Color = MonitorTheme.glassShadow.opacity(0.55),
    shadowRadius: CGFloat = 14,
    shadowY: CGFloat = 8
  ) {
    self.tint = tint
    self.interactive = interactive
    self.fallbackMaterial = fallbackMaterial
    self.fallbackOverlay = fallbackOverlay
    self.strokeColor = strokeColor
    self.shadowColor = shadowColor
    self.shadowRadius = shadowRadius
    self.shadowY = shadowY
  }

  var body: some View {
    let shape = Capsule()

    if #available(macOS 26, *) {
      shape
        .fill(.clear)
        .glassEffect(monitorGlass(tint: tint, interactive: interactive), in: shape)
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(fallbackMaterial)
        .overlay {
          shape.fill(fallbackOverlay)
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    }
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
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

struct MonitorInsetPanelBackground: View {
  let cornerRadius: CGFloat
  let fillOpacity: Double
  let strokeOpacity: Double

  var body: some View {
    MonitorRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: nil,
      interactive: false,
      fallbackMaterial: .thinMaterial,
      fallbackOverlay: Color.white.opacity(fillOpacity),
      strokeColor: Color.white.opacity(strokeOpacity)
    )
  }
}

struct MonitorGlassCapsuleBackground: View {
  var body: some View {
    MonitorCapsuleGlassBackground(
      tint: nil,
      interactive: false,
      fallbackMaterial: .ultraThinMaterial,
      fallbackOverlay: Color.white.opacity(0.03),
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
    MonitorRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: tint,
      interactive: true,
      fallbackMaterial: .thinMaterial,
      fallbackOverlay: tint?.opacity(0.14) ?? Color.white.opacity(0.05),
      strokeColor: tint?.opacity(0.32) ?? Color.white.opacity(0.10)
    )
  }
}
