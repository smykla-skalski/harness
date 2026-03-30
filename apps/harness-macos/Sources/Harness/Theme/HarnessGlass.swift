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

func harnessChromeAccessibilityValue(for style: HarnessThemeStyle) -> String {
  HarnessTheme.usesGradientChrome(for: style) ? "extended" : "reduced"
}

func harnessInteractiveCardAccessibilityValue(for style: HarnessThemeStyle) -> String {
  HarnessTheme.usesGradientChrome(for: style) ? "native-glass" : "bordered-fallback"
}

struct HarnessRoundedGlassBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle

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
    shadowColor: Color = .black.opacity(0.16),
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
    return HarnessTheme.panel(for: themeStyle)
  }

  private var resolvedShadowColor: Color {
    HarnessTheme.usesGradientChrome(for: themeStyle)
      ? shadowColor
      : shadowColor.opacity(0.65)
  }

  private var resolvedFillOpacity: Double {
    fillOpacity.clamped(to: 0...1)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      shape
        .fill(.clear)
        .glassEffect(harnessGlass(tint: tint, interactive: interactive), in: shape)
        .overlay {
          shape.fill(resolvedFillColor.opacity(resolvedFillOpacity))
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: resolvedShadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(resolvedFillColor.opacity(resolvedFillOpacity))
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(
          color: resolvedShadowColor,
          radius: max(4, shadowRadius * 0.35),
          x: 0,
          y: max(2, shadowY * 0.25)
        )
    }
  }
}

struct HarnessCapsuleGlassBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle

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
    shadowColor: Color = .black.opacity(0.09),
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
    return HarnessTheme.surface(for: themeStyle)
  }

  private var resolvedFillOpacity: Double {
    fillOpacity.clamped(to: 0...1)
  }

  var body: some View {
    let shape = Capsule()

    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      shape
        .fill(.clear)
        .glassEffect(harnessGlass(tint: tint, interactive: interactive), in: shape)
        .overlay {
          shape.fill(resolvedFillColor.opacity(resolvedFillOpacity))
        }
        .overlay {
          shape.stroke(strokeColor, lineWidth: 1)
        }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
    } else {
      shape
        .fill(resolvedFillColor.opacity(resolvedFillOpacity))
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
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

extension View {
  func harnessExtendedChromeBackground<Background: View>(
    @ViewBuilder _ background: () -> Background
  ) -> some View {
    modifier(HarnessExtendedChromeBackgroundModifier(background: background()))
  }
}

private struct HarnessExtendedChromeBackgroundModifier<Background: View>: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let background: Background

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      content.background {
        background
          .backgroundExtensionEffect()
          .ignoresSafeArea()
      }
    } else {
      content.background {
        background
          .ignoresSafeArea()
      }
    }
  }
}

struct HarnessInsetPanelBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let cornerRadius: CGFloat
  let fillOpacity: Double
  let strokeOpacity: Double

  var body: some View {
    let resolvedFillOpacity = max(fillOpacity, 0.06)
    let resolvedStrokeOpacity = max(strokeOpacity, 0.10)

    HarnessRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: HarnessTheme.surface(for: themeStyle),
      interactive: false,
      fillOpacity: max(resolvedFillOpacity, 0.08),
      strokeColor: Color.white.opacity(resolvedStrokeOpacity)
    )
  }
}

struct HarnessGlassCapsuleBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle

  var body: some View {
    HarnessCapsuleGlassBackground(
      tint: HarnessTheme.surface(for: themeStyle),
      interactive: false,
      fillOpacity: 0.10,
      strokeColor: HarnessTheme.glassStroke(for: themeStyle),
      shadowColor: HarnessTheme.glassShadow(for: themeStyle).opacity(0.55),
      shadowRadius: 14,
      shadowY: 8
    )
  }
}

struct HarnessInteractiveCardBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let cornerRadius: CGFloat
  let tint: Color?

  var body: some View {
    let resolvedTint = tint ?? HarnessTheme.surface(for: themeStyle)

    HarnessRoundedGlassBackground(
      cornerRadius: cornerRadius,
      tint: resolvedTint,
      interactive: true,
      fillOpacity: tint == nil ? 0.12 : 0.16,
      strokeColor: tint?.opacity(0.32) ?? Color.white.opacity(0.10)
    )
  }
}

private extension Comparable {
  func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
