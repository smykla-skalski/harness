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
  @Environment(\.accessibilityReduceMotion)
  private var reduceMotion

  private static let iconSize: CGFloat = 22

  func makeBody(configuration: Configuration) -> some View {
    let pressed = configuration.isPressed

    configuration.label
      .frame(width: Self.iconSize, height: Self.iconSize)
      // Color: secondary at rest, accent on hover/press.
      .foregroundStyle(iconColor(pressed: pressed))
      // Opacity: 40% at rest, full on hover or press.
      .opacity(iconOpacity(pressed: pressed))
      .animation(.easeOut(duration: 0.15), value: isHovered)
      .animation(.easeOut(duration: 0.15), value: isEnabled)
      // Rotation: 75 degrees clockwise on hover. Instant when Reduce Motion is on.
      .rotationEffect(.degrees(isHovered ? 75 : 0))
      .animation(
        reduceMotion ? .easeOut(duration: 0.1) : .spring(duration: 0.35, bounce: 0.15),
        value: isHovered
      )
      // Scale: snap down on press, spring back on release. Cancelable mid-flight
      // so rapid taps feel responsive - the spring always starts from the current
      // render-tree position, never queuing stale sequences.
      .scaleEffect(pressed ? 0.78 : 1)
      .animation(.spring(duration: 0.2, bounce: 0.3), value: pressed)
      .contentShape(Circle())
      .onContinuousHover { phase in
        switch phase {
        case .active: isHovered = true
        case .ended: isHovered = false
        }
      }
  }

  private func iconColor(pressed: Bool) -> Color {
    if !isEnabled { return HarnessTheme.secondaryInk }
    if pressed || isHovered { return HarnessTheme.accent }
    return HarnessTheme.secondaryInk
  }

  private func iconOpacity(pressed: Bool) -> Double {
    if !isEnabled { return 0.3 }
    if pressed || isHovered { return 1 }
    return 0.4
  }
}
