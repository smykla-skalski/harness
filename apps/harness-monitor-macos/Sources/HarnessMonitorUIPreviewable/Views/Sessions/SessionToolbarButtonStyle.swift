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

    static func resolved(fontScale: CGFloat) -> ResolvedMetrics {
      ResolvedMetrics(fontScale: fontScale)
    }
  }

  struct ResolvedMetrics: Equatable {
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let minHeight: CGFloat
    let iconWidth: CGFloat

    init(fontScale: CGFloat) {
      let scale = SessionWindowFontScale.metricsScale(for: fontScale)
      cornerRadius = Metrics.cornerRadius * min(scale, 1.25)
      horizontalPadding = Metrics.horizontalPadding * min(scale, 1.45)
      verticalPadding = Metrics.verticalPadding * min(scale, 1.45)
      minHeight = max(Metrics.minHeight, Metrics.minHeight * scale)
      iconWidth = max(Metrics.iconWidth, Metrics.iconWidth * min(scale, 1.35))
    }
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
