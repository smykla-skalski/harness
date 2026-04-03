import HarnessKit
import SwiftUI

struct DaemonStatusCard: View {
  let connectionState: HarnessStore.ConnectionState
  let isBusy: Bool
  let isRefreshing: Bool
  let projectCount: Int
  let sessionCount: Int
  let isLaunchAgentInstalled: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let stopDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action

  private var isLoading: Bool {
    isBusy || isRefreshing || connectionState == .connecting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      DaemonCardHeader(
        connectionLabel: connectionLabel,
        isLoading: isLoading,
        isDaemonOnline: isDaemonOnline,
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        startDaemon: startDaemon,
        stopDaemon: stopDaemon,
        statusTitle: statusTitle,
        statusColor: statusColor
      )

      Group {
        if isRefreshing || connectionState == .connecting {
          HarnessLoadingStateView(title: loadingTitle, chrome: .content)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }

      DaemonMetricsStrip(
        projectCount: projectCount,
        sessionCount: sessionCount,
        launchdState: daemonLaunchdState
      )

      DaemonActionButtons(
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        isLoading: isLoading,
        installLaunchAgent: installLaunchAgent
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.daemonCard)
    .accessibilityFrameMarker(HarnessAccessibility.daemonCardFrame)
  }
}

extension DaemonStatusCard {
  fileprivate var isDaemonOnline: Bool {
    connectionState == .online
  }

  fileprivate var connectionLabel: String {
    switch connectionState {
    case .idle:
      "Waiting for bootstrap"
    case .connecting:
      "Connecting to local control plane"
    case .online:
      "Streaming live session updates"
    case .offline(let message):
      message
    }
  }

  fileprivate var loadingTitle: String {
    switch connectionState {
    case .connecting:
      "Connecting to the control plane"
    default:
      "Refreshing session index"
    }
  }

  fileprivate var statusTitle: String {
    switch connectionState {
    case .online:
      "Online"
    case .connecting:
      "Connecting"
    case .idle:
      "Idle"
    case .offline:
      "Offline"
    }
  }

  fileprivate var statusColor: Color {
    switch connectionState {
    case .online:
      HarnessTheme.success
    case .connecting:
      HarnessTheme.caution
    case .idle:
      HarnessTheme.accent
    case .offline:
      HarnessTheme.danger
    }
  }

  fileprivate var daemonLaunchdState: String {
    isLaunchAgentInstalled ? "Installed" : "Manual"
  }
}

struct DaemonStatBadge: View {
  let title: String
  let value: String
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .scaledFont(.caption2.weight(.semibold))
        .tracking(HarnessTheme.uppercaseTracking)
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .scaledFont(.system(.callout, design: .rounded, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(.horizontal, HarnessTheme.cardPadding)
    .padding(.vertical, HarnessTheme.itemSpacing)
    .background {
      RoundedRectangle(cornerRadius: HarnessTheme.cornerRadiusMD, style: .continuous)
        .fill(.primary.opacity(backgroundFillOpacity))
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonBadge(title))
  }

  private var backgroundFillOpacity: Double {
    if reduceTransparency {
      return colorSchemeContrast == .increased ? 0.18 : 0.14
    }
    return colorSchemeContrast == .increased ? 0.09 : 0.05
  }
}

struct DaemonSidebarLayoutProbe<Content: View>: View {
  let identifier: String
  @ViewBuilder let content: Content

  init(_ identifier: String, @ViewBuilder content: () -> Content) {
    self.identifier = identifier
    self.content = content()
  }

  var body: some View {
    content
      .accessibilityFrameMarker(identifier)
  }
}

struct DaemonToggleButtonStyle: ButtonStyle {
  let isLoading: Bool
  let isOnline: Bool
  @State private var isHovered = false

  private static let iconSize: CGFloat = 22

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed

    configuration.label
      .frame(width: Self.iconSize, height: Self.iconSize)
      .foregroundStyle(iconColor(pressed: pressed))
      .opacity(iconOpacity(pressed: pressed))
      .scaleEffect(pressScale(pressed: pressed))
      .animation(.easeOut(duration: 0.15), value: isHovered)
      .animation(.easeOut(duration: 0.15), value: isLoading)
      .animation(.spring(duration: 0.2, bounce: 0.3), value: pressed)
      .contentShape(Circle())
      .onContinuousHover { phase in
        switch phase {
        case .active: isHovered = true
        case .ended: isHovered = false
        }
      }
  }

  private func pressScale(pressed: Bool) -> CGFloat {
    pressed ? 0.8 : 1
  }

  private func iconColor(pressed: Bool) -> Color {
    if isLoading { return HarnessTheme.secondaryInk }
    if pressed || isHovered { return isOnline ? HarnessTheme.danger : HarnessTheme.success }
    return HarnessTheme.secondaryInk
  }

  private func iconOpacity(pressed: Bool) -> Double {
    if isLoading { return 0.5 }
    if pressed || isHovered { return 1 }
    return 0.8
  }
}
