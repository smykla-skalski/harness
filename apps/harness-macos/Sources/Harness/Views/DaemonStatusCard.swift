import HarnessKit
import Observation
import SwiftUI

struct DaemonStatusCard: View {
  let store: HarnessStore

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Harness Daemon")
            .font(.system(.title3, design: .rounded, weight: .bold))
            .accessibilityAddTraits(.isHeader)
          Text(connectionLabel)
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(HarnessTheme.secondaryInk)
        }
        Spacer()
        HStack(spacing: HarnessTheme.itemSpacing) {
          restartButton
          statusPill
        }
      }

      Group {
        if store.isRefreshing || store.connectionState == .connecting {
          HarnessLoadingStateView(title: loadingTitle)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: store.isRefreshing)
      .animation(.spring(duration: 0.3), value: store.connectionState)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: HarnessTheme.itemSpacing) {
          daemonProjectsBadge
          daemonSessionsBadge
          daemonLaunchdBadge
        }
        VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
          HStack(spacing: HarnessTheme.itemSpacing) {
            daemonProjectsBadge
            daemonSessionsBadge
          }
          daemonLaunchdBadge
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .animation(.spring(duration: 0.3), value: daemonProjectCount)
      .animation(.spring(duration: 0.3), value: daemonSessionCount)
      .animation(.spring(duration: 0.3), value: daemonLaunchdState)

      daemonActionButtons
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
    store.connectionState == .online
  }

  fileprivate var isLaunchAgentInstalled: Bool {
    store.daemonStatus?.launchAgent.installed == true
  }

  fileprivate var restartButton: some View {
    Button {
      Task { await store.startDaemon() }
    } label: {
      Image(systemName: "arrow.clockwise")
        .font(.system(size: 14, weight: .semibold))
    }
    .buttonStyle(DaemonRestartButtonStyle())
    .disabled(isLoading)
    .help(isDaemonOnline ? "Restart daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Restart Daemon" : "Start Daemon")
    .accessibilityIdentifier(HarnessAccessibility.sidebarStartDaemonButton)
  }

  fileprivate var daemonActionButtons: some View {
    Group {
      if !isDaemonOnline || !isLaunchAgentInstalled {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          if !isDaemonOnline {
            sidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
              HarnessAsyncActionButton(
                title: "Start Daemon",
                tint: nil,
                variant: .prominent,
                isLoading: isLoading,
                accessibilityIdentifier: "harness.sidebar.action.start.full",
                fillsWidth: false,
                store: store,
                storeAction: .startDaemon
              )
            }
          }
          if !isLaunchAgentInstalled {
            sidebarLayoutProbe(HarnessAccessibility.sidebarInstallLaunchAgentButtonFrame) {
              HarnessAsyncActionButton(
                title: "Install Launch Agent",
                tint: .secondary,
                variant: .bordered,
                isLoading: isLoading,
                accessibilityIdentifier: HarnessAccessibility.sidebarInstallLaunchAgentButton,
                fillsWidth: false,
                store: store,
                storeAction: .installLaunchAgent
              )
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  fileprivate var connectionLabel: String {
    switch store.connectionState {
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
    switch store.connectionState {
    case .connecting:
      "Connecting to the control plane"
    default:
      "Refreshing session index"
    }
  }

  fileprivate var statusPill: some View {
    Text(statusTitle)
      .font(.caption.bold())
      .harnessPillPadding()
      .background(statusBackground, in: Capsule())
      .foregroundStyle(HarnessTheme.onContrast)
  }

  fileprivate var statusTitle: String {
    switch store.connectionState {
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

  fileprivate var statusBackground: Color {
    switch store.connectionState {
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

  fileprivate var daemonProjectCount: Int {
    store.daemonStatus?.projectCount ?? store.projects.count
  }

  fileprivate var daemonSessionCount: Int {
    store.daemonStatus?.sessionCount ?? store.sessions.count
  }

  fileprivate var daemonLaunchdState: String {
    store.daemonStatus?.launchAgent.installed == true ? "Installed" : "Manual"
  }

  fileprivate var daemonProjectsBadge: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Projects")) {
      statBadge(title: "Projects", value: "\(daemonProjectCount)")
    }
  }

  fileprivate var daemonSessionsBadge: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Sessions")) {
      statBadge(title: "Sessions", value: "\(daemonSessionCount)")
    }
  }

  fileprivate var daemonLaunchdBadge: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Launchd")) {
      statBadge(title: "Launchd", value: daemonLaunchdState)
    }
  }

  fileprivate func statBadge(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .tracking(HarnessTheme.uppercaseTracking)
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(.callout, design: .rounded, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(minHeight: 36, alignment: .topLeading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonBadge(title))
  }

  fileprivate func sidebarLayoutProbe<Content: View>(
    _ identifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier(identifier)
  }
}

private struct DaemonRestartButtonStyle: ButtonStyle {
  @State private var isHovered = false
  @Environment(\.isEnabled)
  private var isEnabled

  /// Match the status pill height: caption.bold line height + pill padding top/bottom.
  private static let iconSize: CGFloat = 22

  private var foreground: Color {
    if !isEnabled { return HarnessTheme.secondaryInk.opacity(0.5) }
    if isHovered { return HarnessTheme.accent }
    return HarnessTheme.secondaryInk
  }

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: Self.iconSize, height: Self.iconSize)
      .foregroundStyle(foreground)
      .rotationEffect(.degrees(isHovered ? 75 : 0))
      .scaleEffect(configuration.isPressed ? 0.85 : 1)
      .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
      .animation(.spring(duration: 0.3, bounce: 0.2), value: isHovered)
      .contentShape(Circle())
      .onContinuousHover { phase in
        switch phase {
        case .active: isHovered = true
        case .ended: isHovered = false
        }
      }
  }
}
