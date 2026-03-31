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
          .transition(.opacity)
      }
      Text(title)
        .lineLimit(1)
    }
    .font(.system(.callout, design: .rounded, weight: .semibold))
    .frame(maxWidth: fillsWidth ? .infinity : nil)
    .animation(.spring(duration: 0.2), value: isLoading)
  }

  private func launchAction() {
    Task {
      await action()
    }
  }
}

private struct HarnessActionButtonStyleModifier: ViewModifier {
  let variant: HarnessAsyncActionButton.Variant
  let tint: Color

  @ViewBuilder
  func body(content: Content) -> some View {
    switch variant {
    case .prominent:
      content
        .buttonStyle(.glassProminent)
        .tint(tint)
    case .bordered:
      content
        .buttonStyle(.glass)
        .tint(tint)
    }
  }
}

private struct HarnessAccessoryButtonStyleModifier: ViewModifier {
  let tint: Color

  func body(content: Content) -> some View {
    content
      .buttonStyle(.glass)
      .tint(tint)
  }
}

private struct HarnessFilterChipButtonStyleModifier: ViewModifier {
  let isSelected: Bool

  func body(content: Content) -> some View {
    content
      .buttonStyle(.glass)
      .tint(isSelected ? HarnessTheme.accent : HarnessTheme.ink)
      .fontWeight(isSelected ? .bold : .semibold)
  }
}

private struct InteractiveCardModifier: ViewModifier {
  let cornerRadius: CGFloat
  let tint: Color?

  func body(content: Content) -> some View {
    content
      .buttonStyle(.plain)
      .background {
        if let tint {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint.opacity(0.12))
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
