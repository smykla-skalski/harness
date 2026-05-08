import SwiftUI

struct SessionToolbarButtonStyle: ButtonStyle {
  struct Metrics: Equatable {
    static let cornerRadius: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 5
    static let minHeight: CGFloat = 28
    static let iconWidth: CGFloat = 16
    static let pressedScale = 0.98
    static let animationDuration = 0.14
  }

  var isSelected = false

  func makeBody(configuration: Configuration) -> some View {
    SessionToolbarButtonStyleBody(
      configuration: configuration,
      isSelected: isSelected
    )
  }
}

private struct SessionToolbarButtonStyleBody: View {
  let configuration: ButtonStyle.Configuration
  let isSelected: Bool

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.isEnabled)
  private var isEnabled
  @State private var isHovering = false

  private var shape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: SessionToolbarButtonStyle.Metrics.cornerRadius,
      style: .continuous
    )
  }

  private var strokeOpacity: Double {
    if !isEnabled {
      return 0.18
    }
    if configuration.isPressed {
      return 0.64
    }
    return isHovering || isSelected ? 0.48 : 0.24
  }

  private var tintOpacity: Double {
    if !isEnabled {
      return 0.08
    }
    if configuration.isPressed {
      return 0.24
    }
    return isHovering || isSelected ? 0.18 : 0
  }

  private var lineWidth: CGFloat {
    colorSchemeContrast == .increased ? 1.25 : 1
  }

  var body: some View {
    configuration.label
      .labelStyle(.titleAndIcon)
      .font(.system(.callout, design: .rounded, weight: .semibold))
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(isEnabled ? 0.96 : 0.52))
      .padding(.horizontal, SessionToolbarButtonStyle.Metrics.horizontalPadding)
      .padding(.vertical, SessionToolbarButtonStyle.Metrics.verticalPadding)
      .frame(minHeight: SessionToolbarButtonStyle.Metrics.minHeight)
      .harnessFloatingControlGlass(
        cornerRadius: SessionToolbarButtonStyle.Metrics.cornerRadius,
        tint: HarnessMonitorTheme.ink,
        prominence: .subdued
      )
      .overlay {
        shape.fill(HarnessMonitorTheme.accent.opacity(tintOpacity))
      }
      .overlay {
        shape.strokeBorder(
          HarnessMonitorTheme.controlBorder.opacity(strokeOpacity),
          lineWidth: lineWidth
        )
      }
      .contentShape(shape)
      .scaleEffect(configuration.isPressed ? SessionToolbarButtonStyle.Metrics.pressedScale : 1)
      .onHover { isHovering = $0 }
      .animation(
        reduceMotion
          ? nil
          : .easeOut(duration: SessionToolbarButtonStyle.Metrics.animationDuration),
        value: configuration.isPressed
      )
      .animation(
        reduceMotion
          ? nil
          : .easeOut(duration: SessionToolbarButtonStyle.Metrics.animationDuration),
        value: isHovering
      )
      .animation(
        reduceMotion
          ? nil
          : .easeOut(duration: SessionToolbarButtonStyle.Metrics.animationDuration),
        value: isSelected
      )
  }
}
