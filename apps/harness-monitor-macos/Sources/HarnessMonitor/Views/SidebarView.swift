import HarnessMonitorKit
import Observation
import SwiftUI

struct SidebarView: View {
  @Bindable var store: MonitorStore

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    ZStack(alignment: .topLeading) {
      sidebarChromeBackground

      VStack(spacing: 0) {
        Color.clear
          .frame(height: 8)
          .accessibilityHidden(true)

        ScrollView(showsIndicators: false) {
          VStack(alignment: .leading, spacing: 18) {
            daemonStatusCard
            sessionList
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(.horizontal, 18)
          .padding(.top, 8)
          .padding(.bottom, 18)
        }
        .contentShape(Rectangle())
        .accessibilityFrameMarker(MonitorAccessibility.sidebarShellFrame)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .animation(.snappy(duration: 0.24), value: store.groupedSessions)
    .animation(.snappy(duration: 0.24), value: store.isRefreshing)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sidebarRoot)
  }

  private var daemonStatusCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Harness Daemon")
            .font(.system(.title3, design: .rounded, weight: .bold))
          Text(connectionLabel)
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        statusPill
      }

      if store.connectionState == .online {
        ConnectionStatusStrip(
          metrics: store.connectionMetrics,
          isActive: store.dataReceivedPulse
        )
        .transition(.move(edge: .top).combined(with: .opacity))
      }
      if store.isRefreshing || store.connectionState == .connecting {
        MonitorLoadingStateView(title: loadingTitle)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      HStack(spacing: 8) {
        daemonProjectsBadge
        daemonSessionsBadge
        daemonLaunchdBadge
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      daemonActionButtons
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background {
      MonitorInsetPanelBackground(
        cornerRadius: 22,
        fillOpacity: 0.05,
        strokeOpacity: 0.09
      )
    }
    .accessibilityIdentifier(MonitorAccessibility.daemonCard)
    .accessibilityFrameMarker(MonitorAccessibility.daemonCardFrame)
  }

  private var sessionList: some View {
    SidebarSessionList(store: store)
  }
}

extension SidebarView {
  fileprivate var sidebarChromeBackground: some View {
    Rectangle()
      .fill(.regularMaterial)
      .overlay {
        MonitorTheme.sidebarBackground.opacity(0.22)
      }
      .overlay(alignment: .top) {
        LinearGradient(
          colors: [
            MonitorTheme.glassHighlight,
            Color.white.opacity(0.03),
            .clear,
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      .ignoresSafeArea(edges: .top)
  }

  fileprivate var sidebarStartDaemonButton: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarStartDaemonButtonFrame) {
      MonitorAsyncActionButton(
        title: "Start Daemon",
        tint: MonitorTheme.accent,
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: MonitorAccessibility.sidebarStartDaemonButton,
        fillsWidth: false
      ) {
        await store.startDaemon()
      }
    }
  }

  fileprivate var sidebarInstallLaunchAgentButton: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarInstallLaunchAgentButtonFrame) {
      MonitorAsyncActionButton(
        title: "Install Launch Agent",
        tint: MonitorTheme.ink,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: MonitorAccessibility.sidebarInstallLaunchAgentButton,
        fillsWidth: false
      ) {
        await store.installLaunchAgent()
      }
    }
  }

  fileprivate var daemonActionButtons: some View {
    MonitorGlassContainer(spacing: 8) {
      MonitorWrapLayout(spacing: 8, lineSpacing: 8) {
        sidebarStartDaemonButton
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
      .padding(.horizontal, 9)
      .padding(.vertical, 5)
      .background(statusBackground, in: Capsule())
      .foregroundStyle(.white)
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
      MonitorTheme.success
    case .connecting:
      MonitorTheme.caution
    case .idle:
      MonitorTheme.accent
    case .offline:
      MonitorTheme.danger
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
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Projects")) {
      statBadge(title: "Projects", value: "\(daemonProjectCount)")
    }
  }

  fileprivate var daemonSessionsBadge: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Sessions")) {
      statBadge(title: "Sessions", value: "\(daemonSessionCount)")
    }
  }

  fileprivate var daemonLaunchdBadge: some View {
    sidebarLayoutProbe(MonitorAccessibility.sidebarDaemonBadgeFrame("Launchd")) {
      statBadge(title: "Launchd", value: daemonLaunchdState)
    }
  }

  fileprivate func statBadge(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.callout, design: .rounded, weight: .bold))
        .lineLimit(1)
        .minimumScaleFactor(0.82)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .frame(minHeight: 36, alignment: .topLeading)
    .padding(.vertical, 2)
    .padding(.horizontal, 8)
    .background {
      MonitorInsetPanelBackground(
        cornerRadius: 14,
        fillOpacity: 0.03,
        strokeOpacity: 0.08
      )
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(MonitorAccessibility.sidebarDaemonBadge(title))
  }

  fileprivate func sidebarLayoutProbe<Content: View>(
    _ identifier: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    ZStack(alignment: .topLeading) {
      content()
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(identifier)
  }
}
