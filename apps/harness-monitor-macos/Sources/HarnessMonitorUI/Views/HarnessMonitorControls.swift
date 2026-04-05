import AppKit
import SwiftUI

extension EnvironmentValues {
  @Entry var prominentButtonForeground: Color?
}

enum HarnessMonitorControlMetrics {
  static let compactControlSize: ControlSize = .small
  fileprivate static let disabledButtonChromeBehavior: HarnessMonitorDisabledChromeBehavior =
    .regularize
}

private enum HarnessMonitorDisabledChromeBehavior {
  case regularize
  case preserveConfiguredStyle
}

private enum HarnessMonitorSystemButtonChromeStyle {
  case borderless
  case bordered
  case borderedProminent
}

private struct HarnessMonitorActionButtonStyleModifier: ViewModifier {
  let variant: HarnessMonitorAsyncActionButton.Variant
  let tint: Color?

  private var style: HarnessMonitorSystemButtonChromeStyle {
    switch variant {
    case .prominent:
      .borderedProminent
    case .bordered:
      .bordered
    case .borderless:
      .borderless
    }
  }

  func body(content: Content) -> some View {
    content.modifier(HarnessMonitorSystemButtonChromeModifier(style: style, tint: tint))
  }
}

private struct HarnessMonitorAccessoryButtonStyle: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content
      .modifier(HarnessMonitorSystemButtonChromeModifier(style: .bordered, tint: tint))
  }
}

private struct HarnessMonitorFlatActionButtonStyle: ButtonStyle {
  @ScaledMetric(relativeTo: .caption) private var cornerRadius = 9.0
  @ScaledMetric(relativeTo: .caption) private var horizontalPadding = 10.0
  @ScaledMetric(relativeTo: .caption) private var verticalPadding = 4.0

  let tint: Color
  @Environment(\.isEnabled)
  private var isEnabled
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  private var lineWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.25 : 1
  }

  func makeBody(configuration: Configuration) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: cornerRadius,
      style: .continuous
    )
    let fillOpacity: Double
    let strokeOpacity: Double

    if isEnabled {
      fillOpacity = configuration.isPressed ? 0.34 : 0.26
      strokeOpacity = configuration.isPressed ? 0.68 : 0.5
    } else {
      fillOpacity = 0.14
      strokeOpacity = 0.24
    }

    return configuration.label
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(isEnabled ? 0.98 : 0.55))
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background {
        shape.fill(tint.opacity(fillOpacity))
      }
      .overlay {
        shape.strokeBorder(tint.opacity(strokeOpacity), lineWidth: lineWidth)
      }
      .contentShape(shape)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct HarnessMonitorFilterChipStyle: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      .modifier(
        HarnessMonitorSystemButtonChromeModifier(
          style: isSelected ? .borderedProminent : .bordered,
          tint: isSelected ? nil : .secondary
        )
      )
      .fontWeight(isSelected ? .bold : .semibold)
  }
}

private struct HarnessMonitorSystemButtonChromeModifier: ViewModifier {
  let style: HarnessMonitorSystemButtonChromeStyle
  let tint: Color?

  @Environment(\.isEnabled)
  private var isEnabled

  private var effectiveTint: Color? {
    guard !isEnabled else { return tint }
    switch HarnessMonitorControlMetrics.disabledButtonChromeBehavior {
    case .regularize:
      return .secondary
    case .preserveConfiguredStyle:
      return tint
    }
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    // Keep the underlying AppKit button style stable across enabled-state changes.
    switch style {
    case .borderless:
      if let effectiveTint {
        content.buttonStyle(.borderless).tint(effectiveTint)
      } else {
        content.buttonStyle(.borderless)
      }
    case .bordered:
      if let effectiveTint {
        content.buttonStyle(.bordered).tint(effectiveTint)
      } else {
        content.buttonStyle(.bordered)
      }
    case .borderedProminent:
      if let effectiveTint {
        content
          .buttonStyle(.borderedProminent)
          .tint(effectiveTint)
          .environment(
            \.prominentButtonForeground,
            HarnessMonitorProminentButtonContrast.foreground(for: effectiveTint)
          )
      } else {
        content.buttonStyle(.borderedProminent)
      }
    }
  }
}

private enum HarnessMonitorProminentButtonContrast {
  private static let darkForeground = Color.black.opacity(0.82)
  private static let lightForeground = HarnessMonitorTheme.onContrast

  static func foreground(for tint: Color) -> Color {
    guard let rgbColor = NSColor(tint).usingColorSpace(NSColorSpace.deviceRGB)
    else {
      return lightForeground
    }

    let bgLuminance = relativeLuminance(
      red: rgbColor.redComponent,
      green: rgbColor.greenComponent,
      blue: rgbColor.blueComponent
    )

    let contrastWithWhite = (1.0 + 0.05) / (bgLuminance + 0.05)
    let contrastWithDark = (bgLuminance + 0.05) / (0.03 + 0.05)

    return contrastWithDark >= contrastWithWhite ? darkForeground : lightForeground
  }

  private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
    (0.2126 * linearized(red)) + (0.7152 * linearized(green)) + (0.0722 * linearized(blue))
  }

  private static func linearized(_ component: CGFloat) -> CGFloat {
    if component <= 0.04045 {
      return component / 12.92
    }
    return pow((component + 0.055) / 1.055, 2.4)
  }
}

extension View {
  func harnessActionButtonStyle(
    variant: HarnessMonitorAsyncActionButton.Variant,
    tint: Color? = nil
  ) -> some View {
    modifier(HarnessMonitorActionButtonStyleModifier(variant: variant, tint: tint))
  }

  func harnessAccessoryButtonStyle(
    tint: Color = .secondary
  ) -> some View {
    modifier(HarnessMonitorAccessoryButtonStyle(tint: tint))
  }

  func harnessFlatActionButtonStyle(
    tint: Color = HarnessMonitorTheme.controlBorder
  ) -> some View {
    buttonStyle(HarnessMonitorFlatActionButtonStyle(tint: tint))
  }

  func harnessFilterChipButtonStyle(isSelected: Bool) -> some View {
    modifier(HarnessMonitorFilterChipStyle(isSelected: isSelected))
  }

  func harnessDismissButtonStyle() -> some View {
    modifier(HarnessMonitorSystemButtonChromeModifier(style: .borderless, tint: nil))
  }
}
