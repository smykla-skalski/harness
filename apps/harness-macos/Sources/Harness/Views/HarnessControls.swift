import HarnessKit
import SwiftUI

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
  enum Variant: Equatable {
    case prominent
    case bordered
  }

  enum StoreAction: Equatable {
    case startDaemon
    case installLaunchAgent
    case removeLaunchAgent
    case refresh
    case reconnect
    case refreshDiagnostics
  }

  let title: String
  let tint: Color?
  let variant: Variant
  let isLoading: Bool
  let accessibilityIdentifier: String
  let fillsWidth: Bool
  let store: HarnessStore
  let storeAction: StoreAction

  init(
    title: String,
    tint: Color? = nil,
    variant: Variant,
    isLoading: Bool,
    accessibilityIdentifier: String,
    fillsWidth: Bool = false,
    store: HarnessStore,
    storeAction: StoreAction
  ) {
    self.title = title
    self.tint = tint
    self.variant = variant
    self.isLoading = isLoading
    self.accessibilityIdentifier = accessibilityIdentifier
    self.fillsWidth = fillsWidth
    self.store = store
    self.storeAction = storeAction
  }

  var body: some View {
    Button(action: performAction) {
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
    HStack(spacing: HarnessTheme.itemSpacing) {
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

  private func performAction() {
    Task {
      switch storeAction {
      case .startDaemon:
        await store.startDaemon()
      case .installLaunchAgent:
        await store.installLaunchAgent()
      case .removeLaunchAgent:
        store.requestRemoveLaunchAgentConfirmation()
      case .refresh:
        await store.refresh()
      case .reconnect:
        await store.reconnect()
      case .refreshDiagnostics:
        await store.refreshDiagnostics()
      }
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
        content.buttonStyle(.borderedProminent).tint(effectiveTint)
      } else {
        content.buttonStyle(.borderedProminent)
      }
    }
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
    let fillOpacity = configuration.isPressed ? 0.12 : isHovered ? 0.08 : 0
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
}
