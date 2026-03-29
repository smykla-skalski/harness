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
    .buttonStyle(MonitorActionButtonStyle(variant: variant, tint: tint))
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
    ProgressView()
      .controlSize(.small)
      .fixedSize()
      .accessibilityHidden(true)
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

struct MonitorActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  let variant: MonitorAsyncActionButton.Variant
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foregroundColor)
      .background(background(isPressed: configuration.isPressed))
      .overlay(border)
      .overlay(highlight)
      .clipShape(shape)
      .shadow(
        color: shadowColor(isPressed: configuration.isPressed),
        radius: configuration.isPressed ? 3 : 7,
        x: 0,
        y: configuration.isPressed ? 1 : 4
      )
      .scaleEffect(configuration.isPressed ? 0.996 : 1)
      .opacity(isEnabled ? 1 : 0.62)
      .contentShape(shape)
      .focusEffectDisabled()
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }

  private var foregroundColor: Color {
    switch variant {
    case .prominent:
      .white
    case .bordered:
      MonitorTheme.ink
    }
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(cornerRadius: 13, style: .continuous)
  }

  @ViewBuilder
  private func background(isPressed: Bool) -> some View {
    shape
      .fill(.ultraThinMaterial)
      .overlay {
        switch variant {
        case .prominent:
          LinearGradient(
            colors: [
              tint.opacity(isPressed ? 0.82 : 0.90),
              tint.opacity(isPressed ? 0.68 : 0.78),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        case .bordered:
          LinearGradient(
            colors: [
              MonitorTheme.surfaceHover.opacity(isPressed ? 0.78 : 0.90),
              MonitorTheme.surface.opacity(isPressed ? 0.84 : 0.94),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        }
      }
      .clipShape(shape)
  }

  private var border: some View {
    shape
      .stroke(borderColor, lineWidth: 1)
  }

  private var highlight: some View {
    shape
      .stroke(.white.opacity(0.05), lineWidth: 1)
      .blur(radius: 0.2)
  }

  private var borderColor: Color {
    switch variant {
    case .prominent:
      tint.opacity(0.35)
    case .bordered:
      MonitorTheme.controlBorder
    }
  }

  private func shadowColor(isPressed: Bool) -> Color {
    guard variant == .prominent else {
      return .black.opacity(isPressed ? 0.04 : 0.08)
    }

    return tint.opacity(isPressed ? 0.10 : 0.18)
  }
}
