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

private struct HarnessMonitorTextActionButtonStyle: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content
      .modifier(HarnessMonitorSystemButtonChromeModifier(style: .borderless, tint: tint))
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
      return nil
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

  func harnessTextActionButtonStyle(
    tint: Color = HarnessMonitorTheme.secondaryInk
  ) -> some View {
    modifier(HarnessMonitorTextActionButtonStyle(tint: tint))
  }

  func harnessFilterChipButtonStyle(isSelected: Bool) -> some View {
    modifier(HarnessMonitorFilterChipStyle(isSelected: isSelected))
  }

  func harnessDismissButtonStyle() -> some View {
    modifier(HarnessMonitorSystemButtonChromeModifier(style: .borderless, tint: nil))
  }
}
