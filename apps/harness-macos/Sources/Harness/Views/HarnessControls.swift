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

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content
    } else {
      content.fixedSize(horizontal: true, vertical: true)
    }
  }
}

private struct HarnessFilterChipButtonStyle: ButtonStyle {
  let isSelected: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(HarnessTheme.ink)
      .background {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(backgroundColor(isPressed: configuration.isPressed))
      }
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(strokeStyle, lineWidth: isSelected ? 1.5 : 1)
      }
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isSelected || isPressed {
      return HarnessTheme.usesGradientChrome
        ? HarnessTheme.surfaceHover.opacity(0.78)
        : HarnessTheme.surfaceHover
    }
    return HarnessTheme.usesGradientChrome ? HarnessTheme.surface.opacity(0.55) : HarnessTheme.surface
  }

  private var strokeStyle: AnyShapeStyle {
    if isSelected {
      return AnyShapeStyle(.selection)
    }
    return AnyShapeStyle(
      HarnessTheme.controlBorder.opacity(HarnessTheme.usesGradientChrome ? 0.35 : 0.9)
    )
  }
}

extension View {
  @ViewBuilder
  func harnessActionButtonStyle(
    variant: HarnessAsyncActionButton.Variant,
    tint: Color
  ) -> some View {
    if HarnessTheme.usesGradientChrome {
      switch variant {
      case .prominent:
        self
          .buttonStyle(.glassProminent)
          .tint(tint)
      case .bordered:
        self
          .buttonStyle(.glass(.regular.tint(tint)))
      }
    } else {
      switch variant {
      case .prominent:
        self
          .buttonStyle(.borderedProminent)
          .tint(tint)
      case .bordered:
        self
          .buttonStyle(.bordered)
          .tint(tint)
      }
    }
  }

  @ViewBuilder
  func harnessAccessoryButtonStyle(tint: Color = HarnessTheme.ink) -> some View {
    if HarnessTheme.usesGradientChrome {
      self
        .buttonStyle(.glass(.regular.tint(tint)))
    } else {
      self
        .buttonStyle(.bordered)
        .tint(tint)
    }
  }

  @ViewBuilder
  func harnessFilterChipButtonStyle(
    isSelected: Bool
  ) -> some View {
    self.buttonStyle(HarnessFilterChipButtonStyle(isSelected: isSelected))
  }
}
