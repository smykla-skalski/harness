import HarnessKit
import SwiftUI

struct SessionsBoardOnboardingCard: View {
  let connectionState: HarnessStore.ConnectionState
  let isLaunchAgentInstalled: Bool
  let hasSessions: Bool
  let isLoading: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let refresh: HarnessAsyncActionButton.Action

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SessionsBoardOnboardingHeader(isLaunchAgentInstalled: isLaunchAgentInstalled)
      SessionsBoardOnboardingStepsGrid(
        connectionState: connectionState,
        isLaunchAgentInstalled: isLaunchAgentInstalled,
        hasSessions: hasSessions,
        isLoading: isLoading,
        startDaemon: startDaemon,
        installLaunchAgent: installLaunchAgent,
        refresh: refresh
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityTestProbe(
      HarnessAccessibility.onboardingCard,
      label: "Bring Harness Online",
      value: isLaunchAgentInstalled ? "persistent" : "manual"
    )
    .accessibilityFrameMarker("\(HarnessAccessibility.onboardingCard).frame")
  }

}

private struct SessionsBoardOnboardingHeader: View {
  let isLaunchAgentInstalled: Bool

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        Label("Bring Harness Online", systemImage: "dot.radiowaves.left.and.right")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(
          "Harness only reads live state from the local daemon. "
            + "Start the control plane once, then keep it resident with a launch agent."
        )
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
        .lineSpacing(2)
      }
      Spacer()
      Text(isLaunchAgentInstalled ? "Persistent" : "Manual")
        .scaledFont(.caption.bold())
        .harnessPillPadding()
        .background(HarnessTheme.accent, in: Capsule())
        .foregroundStyle(HarnessTheme.onContrast)
    }
  }
}

private struct SessionsBoardOnboardingStepsGrid: View {
  let connectionState: HarnessStore.ConnectionState
  let isLaunchAgentInstalled: Bool
  let hasSessions: Bool
  let isLoading: Bool
  let startDaemon: HarnessAsyncActionButton.Action
  let installLaunchAgent: HarnessAsyncActionButton.Action
  let refresh: HarnessAsyncActionButton.Action

  var body: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 200,
      maximumColumns: 3,
      spacing: HarnessTheme.sectionSpacing
    ) {
      SessionsBoardOnboardingStepCard(
        title: "1. Start the daemon",
        detail: "Boot the local HTTP and SSE bridge.",
        isReady: connectionState == .online
      ) {
        HarnessAsyncActionButton(
          title: "Start Daemon",
          tint: connectionState == .online
            ? .secondary
            : nil,
          variant: connectionState == .online
            ? .bordered : .prominent,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.start",
          fillsWidth: false,
          action: startDaemon
        )
        .disabled(connectionState == .online)
        .help(connectionState == .online ? "Daemon is already running" : "")
        .focusable(connectionState != .online)
      }
      SessionsBoardOnboardingStepCard(
        title: "2. Install launchd",
        detail: "Keep the daemon available across app restarts.",
        isReady: isLaunchAgentInstalled
      ) {
        HarnessAsyncActionButton(
          title: "Install Launch Agent",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.install",
          fillsWidth: false,
          action: installLaunchAgent
        )
        .disabled(isLaunchAgentInstalled)
        .help(
          isLaunchAgentInstalled ? "Launch agent is already installed" : ""
        )
        .focusable(!isLaunchAgentInstalled)
      }
      SessionsBoardOnboardingStepCard(
        title: "3. Start a harness session",
        detail: "Sessions appear here as soon as the daemon indexes them.",
        isReady: hasSessions
      ) {
        HarnessAsyncActionButton(
          title: "Refresh Index",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.refresh",
          fillsWidth: false,
          action: refresh
        )
      }
    }
  }
}

private struct SessionsBoardOnboardingStepCard<Action: View>: View {
  let title: String
  let detail: String
  let isReady: Bool
  let action: Action

  init(
    title: String,
    detail: String,
    isReady: Bool,
    @ViewBuilder action: () -> Action
  ) {
    self.title = title
    self.detail = detail
    self.isReady = isReady
    self.action = action()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
      HStack(alignment: .top) {
        HStack {
          Circle()
            .fill(isReady ? HarnessTheme.success : HarnessTheme.caution)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
          Text(title)
            .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        }
        Spacer()
        Text(isReady ? "Ready" : "Pending")
          .scaledFont(.caption.bold())
          .harnessPillPadding()
          .background(isReady ? HarnessTheme.success : HarnessTheme.caution, in: Capsule())
          .foregroundStyle(HarnessTheme.onContrast)
      }
      Text(detail)
        .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
        .lineLimit(2)
      Spacer(minLength: 0)
      action
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(.leading, HarnessTheme.spacingLG)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(isReady ? HarnessTheme.success : HarnessTheme.caution)
        .frame(width: 4)
    }
    .animation(.spring(duration: 0.3), value: isReady)
  }
}
