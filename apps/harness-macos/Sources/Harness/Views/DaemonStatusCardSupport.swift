import HarnessKit
import SwiftUI

struct DaemonCardHeader: View {
  let connectionLabel: String
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let stopDaemon: HarnessAsyncActionButton.Action
  let statusTitle: String
  let statusColor: Color

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Daemon")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(connectionLabel)
          .scaledFont(.system(.subheadline, design: .rounded, weight: .medium))
          .foregroundStyle(HarnessTheme.secondaryInk)
      }
      Spacer()
      HStack(spacing: HarnessTheme.itemSpacing) {
        DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarStartDaemonButtonFrame) {
          DaemonToggleButton(
            isLoading: isLoading,
            isDaemonOnline: isDaemonOnline,
            startDaemon: startDaemon,
            stopDaemon: stopDaemon
          )
        }
        DaemonStatusDot(
          statusTitle: statusTitle,
          statusColor: statusColor
        )
      }
    }
  }
}

struct DaemonMetricsStrip: View {
  let projectCount: Int
  let sessionCount: Int
  let launchdState: String

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: HarnessTheme.itemSpacing) {
        projectsBadge
        sessionsBadge
        launchdBadge
      }
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        HStack(spacing: HarnessTheme.itemSpacing) {
          projectsBadge
          sessionsBadge
        }
        launchdBadge
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var projectsBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Projects")) {
      DaemonStatBadge(title: "Projects", value: "\(projectCount)")
    }
  }

  private var sessionsBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Sessions")) {
      DaemonStatBadge(title: "Sessions", value: "\(sessionCount)")
    }
  }

  private var launchdBadge: some View {
    DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarDaemonBadgeFrame("Launchd")) {
      DaemonStatBadge(title: "Launchd", value: launchdState)
    }
  }
}

struct DaemonActionButtons: View {
  let isLaunchAgentInstalled: Bool
  let isLoading: Bool
  let installLaunchAgent: HarnessAsyncActionButton.Action

  var body: some View {
    Group {
      if !isLaunchAgentInstalled {
        HarnessWrapLayout(spacing: HarnessTheme.itemSpacing, lineSpacing: HarnessTheme.itemSpacing) {
          DaemonSidebarLayoutProbe(HarnessAccessibility.sidebarInstallLaunchAgentButtonFrame) {
            HarnessAsyncActionButton(
              title: "Install Launch Agent",
              tint: .secondary,
              variant: .bordered,
              isLoading: isLoading,
              accessibilityIdentifier: HarnessAccessibility.sidebarInstallLaunchAgentButton,
              fillsWidth: false,
              action: installLaunchAgent
            )
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
}

private struct DaemonToggleButton: View {
  let isLoading: Bool
  let isDaemonOnline: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let stopDaemon: HarnessAsyncActionButton.Action

  var body: some View {
    Button {
      guard !isLoading else { return }
      Task {
        if isDaemonOnline {
          await stopDaemon()
        } else {
          await startDaemon()
        }
      }
    } label: {
      Image(systemName: "power")
        .scaledFont(.system(.body, weight: .semibold))
    }
    .buttonStyle(DaemonToggleButtonStyle(isLoading: isLoading, isOnline: isDaemonOnline))
    .help(isDaemonOnline ? "Stop daemon" : "Start daemon")
    .accessibilityLabel(isDaemonOnline ? "Stop Daemon" : "Start Daemon")
    .accessibilityIdentifier(HarnessAccessibility.sidebarStartDaemonButton)
  }
}

private struct DaemonStatusDot: View {
  let statusTitle: String
  let statusColor: Color
  @Environment(\.accessibilityReduceTransparency)
  private var reduceTransparency
  @Environment(\.colorSchemeContrast)
  private var colorSchemeContrast

  var body: some View {
    Circle()
      .fill(statusColor.opacity(fillOpacity))
      .frame(width: 12, height: 12)
      .background {
        Circle()
          .strokeBorder(statusColor.opacity(strokeOpacity), lineWidth: 1)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Daemon Status")
      .accessibilityValue(statusTitle)
      .accessibilityIdentifier(HarnessAccessibility.sidebarDaemonStatusBadge)
      .harnessUITestValue("chrome=status-dot")
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
}
