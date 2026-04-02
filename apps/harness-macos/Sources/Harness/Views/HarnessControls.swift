import AppKit
import SwiftUI

extension EnvironmentValues {
  @Entry var prominentButtonForeground: Color?
}

enum HarnessControlMetrics {
  static let compactControlSize: ControlSize = .small
  fileprivate static let disabledButtonChromeBehavior: HarnessDisabledButtonChromeBehavior =
    .regularize
}

private enum HarnessDisabledButtonChromeBehavior {
  case regularize
  case preserveConfiguredStyle
}

private enum HarnessSystemButtonChromeStyle {
  case borderless
  case bordered
  case borderedProminent
}

private struct HarnessActionButtonStyleModifier: ViewModifier {
  let variant: HarnessAsyncActionButton.Variant
  let tint: Color?

  private var style: HarnessSystemButtonChromeStyle {
    switch variant {
    case .prominent:
      .borderedProminent
    case .bordered:
      .bordered
    }
  }

  func body(content: Content) -> some View {
    content.modifier(HarnessSystemButtonChromeModifier(style: style, tint: tint))
  }
}

private struct HarnessAccessoryButtonStyleModifier: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content
      .modifier(HarnessSystemButtonChromeModifier(style: .bordered, tint: tint))
  }
}

private struct HarnessFilterChipButtonStyleModifier: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      .modifier(
        HarnessSystemButtonChromeModifier(
          style: isSelected ? .borderedProminent : .bordered,
          tint: isSelected ? nil : .secondary
        )
      )
      .fontWeight(isSelected ? .bold : .semibold)
  }
}

private struct HarnessSystemButtonChromeModifier: ViewModifier {
  let style: HarnessSystemButtonChromeStyle
  let tint: Color?

  @Environment(\.isEnabled)
  private var isEnabled

  private var effectiveTint: Color? {
    guard !isEnabled else { return tint }
    switch HarnessControlMetrics.disabledButtonChromeBehavior {
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
            HarnessProminentButtonContrast.foreground(for: effectiveTint)
          )
      } else {
        content.buttonStyle(.borderedProminent)
      }
    }
  }
}

private enum HarnessProminentButtonContrast {
  private static let darkForeground = Color.black.opacity(0.82)
  private static let lightForeground = HarnessTheme.onContrast

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
    variant: HarnessAsyncActionButton.Variant,
    tint: Color? = nil
  ) -> some View {
    modifier(HarnessActionButtonStyleModifier(variant: variant, tint: tint))
  }

  func harnessAccessoryButtonStyle(
    tint: Color = .secondary
  ) -> some View {
    modifier(HarnessAccessoryButtonStyleModifier(tint: tint))
  }

  func harnessFilterChipButtonStyle(isSelected: Bool) -> some View {
    modifier(HarnessFilterChipButtonStyleModifier(isSelected: isSelected))
  }

  func harnessDismissButtonStyle() -> some View {
    modifier(HarnessSystemButtonChromeModifier(style: .borderless, tint: nil))
  }
}
