import SwiftUI

enum HarnessControlMetrics {
  static let compactControlSize: ControlSize = .small
  static let actionHorizontalPadding: CGFloat = 10
  static let actionVerticalPadding: CGFloat = 2
  static let actionMinHeight: CGFloat = 26
  static let fullWidthActionMinHeight: CGFloat = 30
  static let chipHorizontalPadding: CGFloat = 8
  static let chipVerticalPadding: CGFloat = 2
  static let chipMinHeight: CGFloat = 26
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
    .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .center)
    .harnessActionButtonStyle(variant: variant, tint: tint)
    .controlSize(HarnessControlMetrics.compactControlSize)
    .disabled(isLoading)
    .accessibilityIdentifier(accessibilityIdentifier)
    .accessibilityFrameMarker("\(accessibilityIdentifier).frame")
  }

  private var label: some View {
    titleView
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .center)
      .overlay(alignment: .leading) {
        if isLoading {
          progressSlot
            .padding(.leading, fillsWidth ? 8 : 6)
        }
      }
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .center)
      .multilineTextAlignment(.center)
      .font(.system(.callout, design: .rounded, weight: .semibold))
      .padding(.horizontal, HarnessControlMetrics.actionHorizontalPadding)
      .padding(.vertical, HarnessControlMetrics.actionVerticalPadding)
      .frame(
        maxWidth: fillsWidth ? .infinity : nil,
        minHeight:
          fillsWidth
          ? HarnessControlMetrics.fullWidthActionMinHeight
          : HarnessControlMetrics.actionMinHeight
      )
      .modifier(FillWidthButtonSizing(isEnabled: fillsWidth))
  }

  private var titleView: some View {
    Text(title)
      .lineLimit(1)
      .minimumScaleFactor(0.78)
      .allowsTightening(true)
      .truncationMode(.tail)
  }

  private func launchAction() {
    Task {
      await action()
    }
  }

  private var progressSlot: some View {
    HarnessSpinner()
  }
}

private struct FillWidthButtonSizing: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    content.fixedSize(horizontal: !isEnabled, vertical: !isEnabled)
  }
}

private struct HarnessActionButtonStyleModifier: ViewModifier {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  let variant: HarnessAsyncActionButton.Variant
  let tint: Color

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      switch variant {
      case .prominent:
        content
          .buttonStyle(.glassProminent)
          .tint(tint)
      case .bordered:
        content
          .buttonStyle(.glass(.regular.tint(tint)))
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
  let tint: Color

  @ViewBuilder
  func body(content: Content) -> some View {
    if HarnessTheme.usesGradientChrome(for: themeStyle) {
      content
        .buttonStyle(.glass(.regular.tint(tint)))
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
  let isSelected: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    let isGradient = HarnessTheme.usesGradientChrome(for: themeStyle)
    if isGradient {
      if isSelected {
        content
          .buttonStyle(.glassProminent)
          .tint(HarnessTheme.accent(for: themeStyle))
      } else {
        content
          .buttonStyle(
            .glass(.regular.tint(HarnessTheme.surface(for: themeStyle)))
          )
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

extension View {
  func harnessActionButtonStyle(
    variant: HarnessAsyncActionButton.Variant,
    tint: Color
  ) -> some View {
    modifier(HarnessActionButtonStyleModifier(variant: variant, tint: tint))
  }

  func harnessAccessoryButtonStyle(tint: Color = HarnessTheme.ink) -> some View {
    modifier(HarnessAccessoryButtonStyleModifier(tint: tint))
  }

  func harnessFilterChipButtonStyle(isSelected: Bool) -> some View {
    modifier(HarnessFilterChipButtonStyleModifier(isSelected: isSelected))
  }
}
