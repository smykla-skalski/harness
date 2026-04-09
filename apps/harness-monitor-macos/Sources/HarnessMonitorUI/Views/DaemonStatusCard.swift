import HarnessMonitorKit
import SwiftUI

struct DaemonStatusCard: View {
  let store: HarnessMonitorStore
  let connectionState: HarnessMonitorStore.ConnectionState
  let isBusy: Bool
  let isRefreshing: Bool
  let isLaunchAgentInstalled: Bool

  private var isLoading: Bool {
    isBusy || isRefreshing || connectionState == .connecting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      DaemonCardHeader(
        store: store,
        connectionLabel: connectionLabel,
        isLoading: isLoading,
        isDaemonOnline: isDaemonOnline,
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        statusTitle: statusTitle,
        statusColor: statusColor
      )

      DaemonActionButtons(
        store: store,
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        isLoading: isLoading
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.bottom, 4)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.daemonCard)
    .accessibilityFrameMarker(HarnessMonitorAccessibility.daemonCardFrame)
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
      HarnessMonitorTheme.success
    case .connecting:
      HarnessMonitorTheme.caution
    case .idle:
      HarnessMonitorTheme.accent
    case .offline:
      HarnessMonitorTheme.danger
    }
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
    if isLoading { return HarnessMonitorTheme.secondaryInk }
    if pressed || isHovered { return isOnline ? HarnessMonitorTheme.danger : HarnessMonitorTheme.success }
    return HarnessMonitorTheme.secondaryInk
  }

  private func iconOpacity(pressed: Bool) -> Double {
    if isLoading { return 0.5 }
    if pressed || isHovered { return 1 }
    return 0.8
  }
}

#Preview("Daemon Status - Online") {
  daemonStatusCardPreview(
    connectionState: .online,
    isBusy: false,
    isRefreshing: false,
    isLaunchAgentInstalled: true
  )
}

#Preview("Daemon Status - Connecting") {
  daemonStatusCardPreview(
    connectionState: .connecting,
    isBusy: true,
    isRefreshing: false,
    isLaunchAgentInstalled: true
  )
}

#Preview("Daemon Status - Offline") {
  daemonStatusCardPreview(
    connectionState: .offline("Daemon is offline. Launch it from the control deck."),
    isBusy: false,
    isRefreshing: false,
    isLaunchAgentInstalled: false
  )
}

@MainActor
private func daemonStatusCardPreview(
  connectionState: HarnessMonitorStore.ConnectionState,
  isBusy: Bool,
  isRefreshing: Bool,
  isLaunchAgentInstalled: Bool
) -> some View {
  DaemonStatusCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .empty),
    connectionState: connectionState,
    isBusy: isBusy,
    isRefreshing: isRefreshing,
    isLaunchAgentInstalled: isLaunchAgentInstalled
  )
  .padding(20)
  .frame(width: 360)
}
