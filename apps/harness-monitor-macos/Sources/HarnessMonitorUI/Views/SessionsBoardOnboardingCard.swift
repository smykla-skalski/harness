import HarnessMonitorKit
import SwiftUI

struct SessionsBoardOnboardingCard: View {
  let connectionState: HarnessMonitorStore.ConnectionState
  let isLaunchAgentInstalled: Bool
  let hasSessions: Bool
  let isLoading: Bool
  let startDaemon: HarnessMonitorAsyncActionButton.Action
  let installLaunchAgent: HarnessMonitorAsyncActionButton.Action
  let refresh: HarnessMonitorAsyncActionButton.Action
  let dismiss: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      SessionsBoardOnboardingHeader(isLaunchAgentInstalled: isLaunchAgentInstalled, dismiss: dismiss)
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
      HarnessMonitorAccessibility.onboardingCard,
      label: "Bring Harness Monitor Online",
      value: isLaunchAgentInstalled ? "persistent" : "manual"
    )
    .accessibilityFrameMarker("\(HarnessMonitorAccessibility.onboardingCard).frame")
  }

}

private struct SessionsBoardOnboardingHeader: View {
  let isLaunchAgentInstalled: Bool
  let dismiss: @MainActor () -> Void

  var body: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
        Label("Bring Harness Monitor Online", systemImage: "dot.radiowaves.left.and.right")
          .scaledFont(.system(.title3, design: .rounded, weight: .bold))
          .accessibilityAddTraits(.isHeader)
        Text(
          "Harness Monitor only reads live state from the local daemon. "
            + "Start the control plane once, then keep it resident with a launch agent."
        )
        .scaledFont(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineSpacing(2)
      }
      Spacer()
      HStack(spacing: 8) {
        Text(isLaunchAgentInstalled ? "Persistent" : "Manual")
          .scaledFont(.caption.bold())
          .harnessPillPadding()
          .background(HarnessMonitorTheme.accent, in: Capsule())
          .foregroundStyle(HarnessMonitorTheme.onContrast)
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark.circle.fill")
            .scaledFont(.title3)
            .foregroundStyle(HarnessMonitorTheme.secondaryInk)
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Circle())
        }
        .accessibilityLabel("Dismiss setup guide")
        .accessibilityIdentifier(HarnessMonitorAccessibility.onboardingDismissButton)
        .help("Dismiss setup guide")
        .harnessDismissButtonStyle()
      }
    }
  }
}

private struct SessionsBoardOnboardingStepsGrid: View {
  let connectionState: HarnessMonitorStore.ConnectionState
  let isLaunchAgentInstalled: Bool
  let hasSessions: Bool
  let isLoading: Bool
  let startDaemon: HarnessMonitorAsyncActionButton.Action
  let installLaunchAgent: HarnessMonitorAsyncActionButton.Action
  let refresh: HarnessMonitorAsyncActionButton.Action

  var body: some View {
    HarnessMonitorAdaptiveGridLayout(
      minimumColumnWidth: 200,
      maximumColumns: 3,
      spacing: HarnessMonitorTheme.sectionSpacing
    ) {
      SessionsBoardOnboardingStepCard(
        title: "1. Start the daemon",
        detail: "Boot the local HTTP and SSE bridge",
        isReady: connectionState == .online
      ) {
        HarnessMonitorAsyncActionButton(
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
        .accessibilityFrameMarker(HarnessMonitorAccessibility.onboardingStartButtonFrame)
      }
      SessionsBoardOnboardingStepCard(
        title: "2. Install launchd",
        detail: "Keep the daemon available across app restarts",
        isReady: isLaunchAgentInstalled
      ) {
        HarnessMonitorAsyncActionButton(
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
        .accessibilityFrameMarker(HarnessMonitorAccessibility.onboardingInstallButtonFrame)
      }
      SessionsBoardOnboardingStepCard(
        title: "3. Start a harness session",
        detail: "Sessions appear here as soon as the daemon indexes them",
        isReady: hasSessions
      ) {
        HarnessMonitorAsyncActionButton(
          title: "Refresh Index",
          tint: .secondary,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.refresh",
          fillsWidth: false,
          action: refresh
        )
        .accessibilityFrameMarker(HarnessMonitorAccessibility.onboardingRefreshButtonFrame)
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
    VStack(alignment: .leading, spacing: HarnessMonitorTheme.itemSpacing) {
      HStack {
        Text(title)
          .scaledFont(.system(.headline, design: .rounded, weight: .semibold))
        Spacer()
        Text(isReady ? "Ready" : "Pending")
          .scaledFont(.caption.bold())
          .harnessPillPadding()
          .background(isReady ? HarnessMonitorTheme.success : HarnessMonitorTheme.caution, in: Capsule())
          .foregroundStyle(HarnessMonitorTheme.onContrast)
      }
      Text(detail)
        .scaledFont(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessMonitorTheme.secondaryInk)
        .lineLimit(2)
      Spacer(minLength: 0)
      action
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity, alignment: .topLeading)
    .padding(.leading, HarnessMonitorTheme.spacingLG)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(isReady ? HarnessMonitorTheme.success : HarnessMonitorTheme.caution)
        .frame(width: 4)
    }
    .animation(.spring(duration: 0.3), value: isReady)
  }
}

#Preview("Onboarding - Manual Setup") {
  sessionsBoardOnboardingPreview(
    connectionState: .offline("Daemon offline"),
    isLaunchAgentInstalled: false,
    hasSessions: false,
    isLoading: false
  )
}

#Preview("Onboarding - Ready") {
  sessionsBoardOnboardingPreview(
    connectionState: .online,
    isLaunchAgentInstalled: true,
    hasSessions: true,
    isLoading: false
  )
}

@MainActor
private func sessionsBoardOnboardingPreview(
  connectionState: HarnessMonitorStore.ConnectionState,
  isLaunchAgentInstalled: Bool,
  hasSessions: Bool,
  isLoading: Bool
) -> some View {
  SessionsBoardOnboardingCard(
    connectionState: connectionState,
    isLaunchAgentInstalled: isLaunchAgentInstalled,
    hasSessions: hasSessions,
    isLoading: isLoading,
    startDaemon: {},
    installLaunchAgent: {},
    refresh: {},
    dismiss: {}
  )
  .padding(24)
  .frame(width: 920)
}
