import SwiftUI

struct MonitorAsyncActionButton: View {
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
    .monitorActionButtonStyle(variant: variant, tint: tint)
    .controlSize(fillsWidth ? .large : .regular)
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
            .padding(.leading, fillsWidth ? 10 : 8)
        }
      }
      .frame(maxWidth: fillsWidth ? .infinity : nil, alignment: .center)
      .multilineTextAlignment(.center)
      .font(.system(.subheadline, design: .rounded, weight: .semibold))
      .padding(.horizontal, fillsWidth ? 12 : 11)
      .padding(.vertical, fillsWidth ? 7 : 4)
      .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: fillsWidth ? 38 : 32)
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
    MonitorSpinner()
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

extension View {
  @ViewBuilder
  func monitorActionButtonStyle(
    variant: MonitorAsyncActionButton.Variant,
    tint: Color
  ) -> some View {
    switch variant {
    case .prominent:
      if #available(macOS 26, *) {
        self
          .buttonStyle(.glassProminent)
          .tint(tint)
      } else {
        self
          .buttonStyle(.borderedProminent)
          .tint(tint)
      }
    case .bordered:
      if #available(macOS 26, *) {
        self
          .buttonStyle(.glass(.regular.tint(tint)))
      } else {
        self
          .buttonStyle(.bordered)
          .tint(tint)
      }
    }
  }

  @ViewBuilder
  func monitorAccessoryButtonStyle(tint: Color = MonitorTheme.ink) -> some View {
    if #available(macOS 26, *) {
      self
        .buttonStyle(.glass(.regular.tint(tint)))
    } else {
      self
        .buttonStyle(.borderless)
        .tint(tint)
    }
  }
}
