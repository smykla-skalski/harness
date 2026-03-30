import SwiftUI

extension EnvironmentValues {
  @Entry var isInsideGlassEffect: Bool = false
}

func harnessGlass(tint: Color? = nil, interactive: Bool = false) -> Glass {
  var glass = Glass.regular
  if let tint {
    glass = glass.tint(tint.opacity(0.35))
  }
  if interactive {
    glass = glass.interactive()
  }
  return glass
}

func effectiveSuppressedGlassFill(_ baseFill: Double) -> Double {
  min(baseFill * 3, 0.35)
}

func harnessChromeAccessibilityValue(for style: HarnessThemeStyle) -> String {
  HarnessTheme.usesGradientChrome(for: style) ? "extended" : "reduced"
}

struct HarnessGlassRenderingMarker: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let identifier: String
  let baseFill: Double

  private var stateText: String {
    let isGradient = HarnessTheme.usesGradientChrome(for: themeStyle)
    if !isGradient {
      return "glass=flat"
    }
    if isInsideGlassEffect {
      let fill = effectiveSuppressedGlassFill(baseFill)
      return "glass=suppressed, fill=\(String(format: "%.2f", fill))"
    }
    return "glass=active"
  }

  var body: some View {
    Color.clear
      .allowsHitTesting(false)
      .accessibilityElement()
      .accessibilityLabel(stateText)
      .accessibilityIdentifier(identifier)
  }
}

func harnessInteractiveCardAccessibilityValue(for style: HarnessThemeStyle) -> String {
  HarnessTheme.usesGradientChrome(for: style) ? "native-glass" : "bordered-fallback"
}

struct HarnessRoundedGlassBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect

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

  private var useGlass: Bool {
    HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect
  }

  private var suppressedGlass: Bool {
    HarnessTheme.usesGradientChrome(for: themeStyle) && isInsideGlassEffect
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

    if useGlass {
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
    } else if suppressedGlass {
      shape
        .fill(resolvedFillColor.opacity(effectiveSuppressedGlassFill(resolvedFillOpacity)))
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
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect

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

  private var useGlass: Bool {
    HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect
  }

  private var suppressedGlass: Bool {
    HarnessTheme.usesGradientChrome(for: themeStyle) && isInsideGlassEffect
  }

  var body: some View {
    let shape = Capsule()

    if useGlass {
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
    } else if suppressedGlass {
      shape
        .fill(resolvedFillColor.opacity(effectiveSuppressedGlassFill(resolvedFillOpacity)))
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
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let spacing: CGFloat?
  private let content: Content

  init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
    self.spacing = spacing
    self.content = content()
  }

  var body: some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect {
      GlassEffectContainer(spacing: spacing) {
        content
      }
    } else {
      content
    }
  }
}

extension View {
  func harnessInsetPanel(
    cornerRadius: CGFloat,
    fillOpacity: Double,
    strokeOpacity: Double
  ) -> some View {
    modifier(
      HarnessInsetPanelModifier(
        cornerRadius: cornerRadius,
        fillOpacity: fillOpacity,
        strokeOpacity: strokeOpacity
      )
    )
  }

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
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let surfaceColor = HarnessTheme.surface(for: themeStyle)
    let resolvedFill = max(fillOpacity, 0.08)

    let strokeColor = HarnessTheme.panelBorder(for: themeStyle)

    shape
      .fill(surfaceColor.opacity(resolvedFill))
      .overlay {
        if strokeOpacity > 0 {
          shape.stroke(strokeColor.opacity(strokeOpacity), lineWidth: 1)
        }
      }
  }
}

private struct HarnessInsetPanelModifier: ViewModifier {
  let cornerRadius: CGFloat
  let fillOpacity: Double
  let strokeOpacity: Double

  func body(content: Content) -> some View {
    ZStack(alignment: .topLeading) {
      content
        .environment(\.isInsideGlassEffect, true)
    }
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: cornerRadius,
        fillOpacity: fillOpacity,
        strokeOpacity: strokeOpacity
      )
    }
  }
}

struct HarnessGlassCapsuleBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle

  var body: some View {
    let shape = Capsule()
    let surfaceColor = HarnessTheme.surface(for: themeStyle)
    let strokeColor = HarnessTheme.glassStroke(for: themeStyle)
    let shadowColor = HarnessTheme.glassShadow(for: themeStyle)

    shape
      .fill(surfaceColor.opacity(0.12))
      .overlay {
        shape.stroke(strokeColor, lineWidth: 1)
      }
      .shadow(color: shadowColor.opacity(0.55), radius: 14, x: 0, y: 8)
  }
}

struct HarnessInteractiveCardBackground: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let cornerRadius: CGFloat
  let tint: Color?

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    let resolvedTint = tint ?? HarnessTheme.surface(for: themeStyle)
    let fillOpacity = tint == nil ? 0.12 : 0.16
    let strokeColor = tint?.opacity(0.32) ?? Color.white.opacity(0.10)

    shape
      .fill(resolvedTint.opacity(fillOpacity))
      .overlay {
        shape.stroke(strokeColor, lineWidth: 1)
      }
  }
}

extension Comparable {
  fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}
