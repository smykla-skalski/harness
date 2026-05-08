import SwiftUI

struct SessionToolbarButtonStyleBody: View {
  let configuration: ButtonStyle.Configuration
  let isSelected: Bool

  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast
  @Environment(\.isEnabled)
  private var isEnabled
  @Environment(\.fontScale)
  private var fontScale
  @State private var isHovering = false

  private var metrics: SessionToolbarButtonStyle.ResolvedMetrics {
    SessionToolbarButtonStyle.Metrics.resolved(fontScale: fontScale)
  }

  private var shape: RoundedRectangle {
    RoundedRectangle(
      cornerRadius: metrics.cornerRadius,
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
      .scaledFont(.system(.callout, design: .rounded, weight: .semibold))
      .foregroundStyle(HarnessMonitorTheme.ink.opacity(isEnabled ? 0.96 : 0.52))
      .padding(.horizontal, metrics.horizontalPadding)
      .padding(.vertical, metrics.verticalPadding)
      .frame(minHeight: metrics.minHeight)
      .harnessFloatingControlGlass(
        cornerRadius: metrics.cornerRadius,
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
