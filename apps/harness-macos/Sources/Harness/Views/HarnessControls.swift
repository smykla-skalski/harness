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

struct HarnessAsyncActionButton: View {
  typealias Action = @MainActor () async -> Void

  enum Variant: Equatable {
    case prominent
    case bordered
  }

  let title: String
  let tint: Color?
  let variant: Variant
  let isLoading: Bool
  let accessibilityIdentifier: String
  let fillsWidth: Bool
  let action: Action
  @State private var runningTask: Task<Void, Never>?

  init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    action: @escaping Action
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.action = action
  }

  private var effectiveVariant: Variant {
    isLoading ? .bordered : variant
  }

  private var effectiveTint: Color? {
    isLoading ? .secondary : tint
  }

  var body: some View {
    Button {
      if isLoading {
        cancelAction()
      } else {
        performAction()
      }
    } label: {
      label
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .harnessActionButtonStyle(variant: effectiveVariant, tint: effectiveTint)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
  }

  private var label: some View {
    ProminentAwareLabel {
      HStack(spacing: HarnessTheme.itemSpacing) {
        if isLoading {
          HarnessSpinner()
            .transition(.opacity)
        }
        Text(isLoading ? "Cancel" : title)
          .lineLimit(1)
      }
      .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
      .frame(maxWidth: fillsWidth ? .infinity : nil)
      .animation(.spring(duration: 0.2), value: isLoading)
    }
  }

  private func performAction() {
    let action = action
    runningTask = Task { @MainActor in
      await action()
      runningTask = nil
    }
  }

  private func cancelAction() {
    runningTask?.cancel()
    runningTask = nil
  }
}

private struct ProminentAwareLabel<Content: View>: View {
  @Environment(\.prominentButtonForeground)
  private var prominentForeground
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    if let prominentForeground {
      content.foregroundStyle(prominentForeground)
    } else {
      content
    }
  }
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

private struct InteractiveCardButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color?
  let isHovered: Bool
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let highlight = tint ?? .primary
    let fillOpacity = configuration.isPressed ? 0.12 : isHovered ? 0.08 : 0.04
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(highlight.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? (configuration.isPressed ? 0.92 : 1) : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct InteractiveCardHoverModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        InteractiveCardButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered
        )
      )
      .onContinuousHover { phase in
        withAnimation(.easeOut(duration: 0.15)) {
          switch phase {
          case .active:
            isHovered = true
          case .ended:
            isHovered = false
          }
        }
      }
      .harnessUITestValue("chrome=content-card")
  }
}

private struct SidebarRowButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color
  let isHovered: Bool
  @Environment(\.isEnabled)
  private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    let fillOpacity = configuration.isPressed ? 0.14 : isHovered ? 0.09 : 0.04
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(tint.opacity(fillOpacity))
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(isEnabled ? 1 : 0.4)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
  }
}

private struct SidebarRowHoverModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color
  @State private var isHovered = false

  func body(content: Content) -> some View {
    content
      .buttonStyle(
        SidebarRowButtonStyle(
          cornerRadius: cornerRadius,
          tint: tint,
          isHovered: isHovered
        )
      )
      .onContinuousHover { phase in
        withAnimation(.easeOut(duration: 0.15)) {
          switch phase {
          case .active:
            isHovered = true
          case .ended:
            isHovered = false
          }
        }
      }
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

  func harnessInteractiveCardButtonStyle(
    cornerRadius: CGFloat = HarnessTheme.cornerRadiusMD,
    tint: Color? = nil
  ) -> some View {
    modifier(
      InteractiveCardHoverModifier(
        cornerRadius: cornerRadius,
        tint: tint
      )
    )
  }

  func harnessSidebarRowButtonStyle(
    cornerRadius: CGFloat = HarnessTheme.cornerRadiusLG,
    tint: Color = HarnessTheme.accent
  ) -> some View {
    modifier(SidebarRowHoverModifier(cornerRadius: cornerRadius, tint: tint))
  }
}
