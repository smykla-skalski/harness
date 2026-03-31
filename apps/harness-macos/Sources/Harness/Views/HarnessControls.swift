import HarnessKit
import SwiftUI

enum HarnessControlMetrics {
  static let compactControlSize: ControlSize = .small
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

  @ViewBuilder
  func body(content: Content) -> some View {
    switch variant {
    case .prominent:
      if let tint {
        content.buttonStyle(.glassProminent).tint(tint)
      } else {
        content.buttonStyle(.glassProminent)
      }
    case .bordered:
      if let tint {
        content.buttonStyle(.glass).tint(tint)
      } else {
        content.buttonStyle(.glass)
      }
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

  @ViewBuilder
  func body(content: Content) -> some View {
    if isSelected {
      content
        .buttonStyle(.glassProminent)
        .fontWeight(.bold)
    } else {
      content
        .buttonStyle(.glass)
        .tint(.secondary)
        .fontWeight(.semibold)
    }
  }
}

private struct InteractiveCardButtonStyle: ButtonStyle {
  let cornerRadius: CGFloat
  let tint: Color?

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        if let tint {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(tint.opacity(configuration.isPressed ? 0.18 : 0.12))
        }
      }
      .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .opacity(configuration.isPressed ? 0.85 : 1)
      .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
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

  func harnessInteractiveCardButtonStyle(
    cornerRadius: CGFloat = 18,
    tint: Color? = nil
  ) -> some View {
    buttonStyle(
      InteractiveCardButtonStyle(
        cornerRadius: cornerRadius,
        tint: tint
      )
    )
  }
}
