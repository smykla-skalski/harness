import SwiftUI

enum HarnessControlMetrics {
  static let compactControlSize: ControlSize = .small
}

struct HarnessAsyncActionButton: View {
  enum Variant: Equatable {
    case prominent
    case bordered
  }

  let title: String
  let tint: Color
  let variant: Variant
  let isLoading: Bool
  let accessibilityIdentifier: String
  let fillsWidth: Bool
  let action: @Sendable () async -> Void

  init(
    title: String,
    tint: Color,
    variant: Variant,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    action: @escaping @Sendable () async -> Void
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.action = action
  }

  var body: some View {
    Button(action: launchAction) {
      label
    }
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .harnessActionButtonStyle(variant: variant, tint: tint)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .disabled(isLoading)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
  }

  private var label: some View {
    HStack(spacing: 6) {
      if isLoading {
        HarnessSpinner()
      }
      Text(title)
        .lineLimit(1)
    }
    .font(.system(.callout, design: .rounded, weight: .semibold))
    .frame(maxWidth: fillsWidth ? .infinity : nil)
  }

  private func launchAction() {
    Task {
      await action()
    }
  }
}

private struct HarnessActionButtonStyleModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let variant: HarnessAsyncActionButton.Variant
  let tint: Color

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect {
      switch variant {
      case .prominent:
        content
          .buttonStyle(.glassProminent)
      case .bordered:
        content
          .buttonStyle(.glass(.regular.tint(tint)))
          .tint(tint)
      }
    } else {
      switch variant {
      case .prominent:
        content
          .buttonStyle(.borderedProminent)
          .tint(tint)
      case .bordered:
        content
          .buttonStyle(.bordered)
          .tint(tint)
      }
    }
  }
}

private struct HarnessAccessoryButtonStyleModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let tint: Color

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect {
      content
        .buttonStyle(.glass(.regular.tint(tint)))
        .tint(tint)
    } else {
      content
        .buttonStyle(.bordered)
        .tint(tint)
    }
  }
}

private struct HarnessFilterChipButtonStyleModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let isSelected: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    let isGradient = HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect
    if isGradient {
      if isSelected {
        content
          .buttonStyle(.glassProminent)
      } else {
        content
          .buttonStyle(
            .glass(.regular.tint(HarnessTheme.surface(for: themeStyle)))
          )
          .tint(HarnessTheme.ink)
      }
    } else {
      if isSelected {
        content
          .buttonStyle(.borderedProminent)
          .tint(HarnessTheme.accent(for: themeStyle))
      } else {
        content
          .buttonStyle(.bordered)
          .tint(HarnessTheme.ink)
      }
    }
  }
}

private struct InteractiveCardModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  let cornerRadius: CGFloat
  let tint: Color?

  @ViewBuilder
  func body(content: Content) -> some View {
    let resolvedTint = tint ?? HarnessTheme.surface(for: themeStyle)

    if HarnessTheme.usesGradientChrome(for: themeStyle) && !isInsideGlassEffect {
      content
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .buttonStyle(.glass(.regular.tint(resolvedTint)))
    } else if let tint {
      content
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .buttonStyle(.borderedProminent)
        .tint(tint)
    } else {
      content
        .buttonBorderShape(.roundedRectangle(radius: cornerRadius))
        .buttonStyle(.bordered)
        .tint(HarnessTheme.ink)
    }
  }
}

extension View {
  func harnessActionButtonStyle(
    variant: HarnessAsyncActionButton.Variant,
    tint: Color
  ) -> some View {
    modifier(HarnessActionButtonStyleModifier(variant: variant, tint: tint))
  }

  func harnessAccessoryButtonStyle(
    tint: Color = HarnessTheme.ink
  ) -> some View {
    modifier(HarnessAccessoryButtonStyleModifier(tint: tint))
  }

  func harnessFilterChipButtonStyle(isSelected: Bool) -> some View {
    modifier(HarnessFilterChipButtonStyleModifier(isSelected: isSelected))
  }

  func harnessInteractiveCardButtonStyle(
    cornerRadius: CGFloat = 18,
    tint: Color? = nil
  ) -> some View {
    modifier(
      InteractiveCardModifier(
        cornerRadius: cornerRadius,
        tint: tint
      )
    )
  }
}
