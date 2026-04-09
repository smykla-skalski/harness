import HarnessMonitorKit
import SwiftUI

private final class ToolbarCenterpieceBundleToken {}
private let centerpieceBundleRef = Bundle(for: ToolbarCenterpieceBundleToken.self)

struct ToolbarDaemonIndicatorIcon: View {
  let indicator: ToolbarDaemonIndicator
  private static let containerWidth: CGFloat = 16

  var body: some View {
    Group {
      switch indicator {
      case .offline:
        Circle()
          .fill(Color.secondary.opacity(0.5))
          .frame(width: 8, height: 8)
      case .launchdConnected:
        Image("LaunchDaemonRocket", bundle: centerpieceBundleRef)
          .renderingMode(.template)
          .resizable()
          .scaledToFit()
          .frame(height: 14)
      case .manualConnected:
        Image(systemName: "person.fill")
          .font(.caption.weight(.semibold))
      }
    }
    .frame(width: Self.containerWidth, alignment: .trailing)
    .foregroundStyle(indicator.foregroundColor)
    .animation(nil, value: indicator)
    .accessibilityHidden(true)
  }
}

struct ToolbarDaemonToggleControl: View {
  let store: HarnessMonitorStore
  let connectionState: HarnessMonitorStore.ConnectionState
  let isBusy: Bool
  @State private var isHovered = false
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Button {
      guard !isLoading else { return }
      Task {
        if isDaemonOnline {
          await store.stopDaemon()
        } else {
          await store.startDaemon()
        }
      }
    } label: {
      ZStack {
        dotLayer
        powerLayer
      }
      .frame(width: 20, height: 20)
      .opacity(isLoading ? 0.7 : 1)
      .contentShape(Circle())
    }
    .buttonStyle(ToolbarDaemonPowerToggleButtonStyle(reduceMotion: reduceMotion))
    .contentShape(Rectangle())
    .onContinuousHover { phase in
      let hovered: Bool
      switch phase {
      case .active:
        hovered = true
      case .ended:
        hovered = false
      }
      guard hovered != isHovered else { return }
      withAnimation(morphAnimation) {
        isHovered = hovered
      }
    }
    .help(isDaemonOnline ? "Stop daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Stop Daemon" : "Start Daemon")
    .accessibilityValue(statusTitle)
    .accessibilityIdentifier(HarnessMonitorAccessibility.toolbarStartDaemonButton)
  }

  private var isDaemonOnline: Bool {
    connectionState == .online
  }

  private var isLoading: Bool {
    isBusy || connectionState == .connecting
  }

  private var statusTitle: String {
    switch connectionState {
    case .online: "Online"
    case .connecting: "Connecting"
    case .idle: "Idle"
    case .offline: "Offline"
    }
  }

  private var statusColor: Color {
    switch connectionState {
    case .online: HarnessMonitorTheme.success
    case .connecting: HarnessMonitorTheme.caution
    case .idle: HarnessMonitorTheme.accent
    case .offline: HarnessMonitorTheme.danger
    }
  }

  private var fillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.88 : 0.8
    }
    return colorSchemeContrast == .increased ? 0.76 : 0.66
  }

  private var strokeOpacity: Double {
    colorSchemeContrast == .increased ? 0.92 : 0.72
  }

  private var dotLayer: some View {
    Circle()
      .fill(statusColor.opacity(fillOpacity))
      .frame(width: 10, height: 10)
      .background {
        Circle()
          .strokeBorder(statusColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .opacity(1 - morphProgress)
      .scaleEffect(1 + (0.7 * morphProgress))
      .blur(radius: 2 * morphProgress)
  }

  private var powerLayer: some View {
    Image(systemName: "power")
      .font(.system(.body, weight: .semibold))
      .foregroundStyle(iconColor)
      .opacity(morphProgress)
      .scaleEffect(0.25 + (0.75 * morphProgress))
      .rotationEffect(.degrees(powerRotationDegrees))
  }

  private var iconColor: Color {
    if isLoading { return HarnessMonitorTheme.secondaryInk }
    return isDaemonOnline ? HarnessMonitorTheme.danger : HarnessMonitorTheme.success
  }

  private var morphAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.12)
    }
    return .interactiveSpring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.18)
  }

  private var morphProgress: CGFloat {
    isHovered ? 1 : 0
  }

  private var powerRotationDegrees: Double {
    Double(-95 + (95 * morphProgress))
  }
}

private struct ToolbarDaemonPowerToggleButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed

    configuration.label
      .scaleEffect(isPressed ? 0.9 : 1)
      .offset(y: isPressed ? 0.35 : 0)
      .brightness(isPressed ? -0.03 : 0)
      .saturation(isPressed ? 0.96 : 1)
      .animation(pressAnimation, value: configuration.isPressed)
  }

  private var pressAnimation: Animation? {
    if reduceMotion {
      return .easeOut(duration: 0.08)
    }
    return .interactiveSpring(response: 0.18, dampingFraction: 0.45, blendDuration: 0.14)
  }
}

struct ToolbarCenterpieceMetricsRow: View {
  let metrics: [ToolbarCenterpieceMetric]
  let displayMode: ToolbarCenterpieceDisplayMode

  var body: some View {
    HStack(spacing: displayMode.metricSpacing) {
      ForEach(metrics, id: \.kind.rawValue) { metric in
        ToolbarCenterpieceMetricToken(metric: metric, displayMode: displayMode)
      }
    }
  }
}

private struct ToolbarCenterpieceMetricToken: View {
  let metric: ToolbarCenterpieceMetric
  let displayMode: ToolbarCenterpieceDisplayMode

  var body: some View {
    HStack(spacing: HarnessMonitorTheme.spacingXS) {
      if !displayMode.showsMetricLabels {
        Image(systemName: metric.kind.symbolName)
          .font(.caption.weight(.bold))
          .foregroundStyle(metric.kind.tint)
          .accessibilityHidden(true)
      }

      Text("\(metric.value)")
        .font(.system(.subheadline, design: .rounded, weight: .bold).monospacedDigit())
        .foregroundStyle(metric.kind.tint)
        .contentTransition(.numericText())

      if displayMode.showsMetricLabels {
        Text(labelText)
          .font(.caption2.weight(.bold))
          .tracking(HarnessMonitorTheme.uppercaseTracking)
          .foregroundStyle(HarnessMonitorTheme.secondaryInk)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
  }

  private var labelText: String {
    metric.kind.title.uppercased()
  }
}
