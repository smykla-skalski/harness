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
        statusPill
      }

      Group {
        if store.connectionState == .online {
          ConnectionStatusStrip(
            metrics: store.connectionMetrics,
            isActive: store.dataReceivedPulse
          )
          .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: store.connectionState)

      Group {
        if store.isRefreshing || store.connectionState == .connecting {
          HarnessLoadingStateView(title: loadingTitle)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
      }
      .animation(.spring(duration: 0.3), value: store.isRefreshing)
      .animation(.spring(duration: 0.3), value: store.connectionState)

      HStack(spacing: HarnessTheme.itemSpacing) {
        daemonProjectsBadge
          .animation(.spring(duration: 0.3), value: daemonProjectCount)
        daemonSessionsBadge
          .animation(.spring(duration: 0.3), value: daemonSessionCount)
        daemonLaunchdBadge
          .animation(.spring(duration: 0.3), value: daemonLaunchdState)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

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

  fileprivate var sidebarStartDaemonButton: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
      HarnessAsyncActionButton(
        title: isDaemonOnline ? "Restart Daemon" : "Start Daemon",
        tint: isDaemonOnline ? .orange : nil,
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.sidebarStartDaemonButton,
        fillsWidth: false,
        store: store,
        storeAction: .startDaemon
      )
    }
  }

  fileprivate var sidebarInstallLaunchAgentButton: some View {
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

  fileprivate var daemonActionButtons: some View {
    HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
      sidebarStartDaemonButton
      if !isLaunchAgentInstalled {
        sidebarInstallLaunchAgentButton
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
