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
        startDaemon: startDaemon,
        statusTitle: statusTitle,
        statusBackground: statusBackground
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
        isDaemonOnline: isDaemonOnline,
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        isLoading: isLoading,
        startDaemon: startDaemon,
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

  fileprivate var statusBackground: Color {
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
