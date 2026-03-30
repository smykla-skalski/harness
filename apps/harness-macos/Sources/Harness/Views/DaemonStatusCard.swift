import HarnessKit
import Observation
import SwiftUI

struct DaemonStatusCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  @Bindable var store: HarnessStore

  private var panelGlassState: String {
    let isGradient = HarnessTheme.usesGradientChrome(for: themeStyle)
    if !isGradient { return "glass=flat" }
    if isInsideGlassEffect {
      let fill = effectiveSuppressedGlassFill(0.08)
      return "glass=suppressed, fill=\(String(format: "%.2f", fill))"
    }
    return "glass=active"
  }

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Harness Daemon")
            .font(.system(.title3, design: .rounded, weight: .bold))
          Text(connectionLabel)
            .font(.system(.subheadline, design: .rounded, weight: .medium))
            .foregroundStyle(HarnessTheme.secondaryInk)
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
        HarnessLoadingStateView(title: loadingTitle)
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
    .harnessInsetPanel(cornerRadius: 22, fillOpacity: 0.05, strokeOpacity: 0.50)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.daemonCardGlassState,
        text: panelGlassState
      )
    }
    .accessibilityValue(panelGlassState)
    .accessibilityIdentifier(HarnessAccessibility.daemonCard)
    .accessibilityFrameMarker(HarnessAccessibility.daemonCardFrame)
  }
}

extension DaemonStatusCard {
  fileprivate var sidebarStartDaemonButton: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
      HarnessAsyncActionButton(
        title: "Start Daemon",
        tint: HarnessTheme.accent(for: themeStyle),
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.sidebarStartDaemonButton,
        fillsWidth: false
      ) {
        await store.startDaemon()
      }
    }
  }

  fileprivate var sidebarInstallLaunchAgentButton: some View {
    sidebarLayoutProbe(HarnessAccessibility.sidebarInstallLaunchAgentButtonFrame) {
      HarnessAsyncActionButton(
        title: "Install Launch Agent",
        tint: HarnessTheme.ink,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: HarnessAccessibility.sidebarInstallLaunchAgentButton,
        fillsWidth: false
      ) {
        await store.installLaunchAgent()
      }
    }
  }

  fileprivate var daemonActionButtons: some View {
    HarnessGlassContainer(spacing: 8) {
      HarnessWrapLayout(spacing: 8, lineSpacing: 8) {
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
      HarnessTheme.success
    case .connecting:
      HarnessTheme.caution
    case .idle:
      HarnessTheme.accent(for: themeStyle)
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
    .harnessInsetPanel(cornerRadius: 14, fillOpacity: 0.03, strokeOpacity: 0.50)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityValue(value)
    .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonBadge(title))
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
