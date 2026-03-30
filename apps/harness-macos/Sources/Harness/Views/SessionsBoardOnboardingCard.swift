import HarnessKit
import Observation
import SwiftUI

struct SessionsBoardOnboardingCard: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Bindable var store: HarnessStore
  let isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      onboardingStepsSection
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.onboardingCard)
  }

  private var header: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Label("Bring Harness Online", systemImage: "dot.radiowaves.left.and.right")
          .font(.system(.title3, design: .rounded, weight: .bold))
        Text(
          "Harness only reads live state from the local daemon. "
            + "Start the control plane once, then keep it resident with a launch agent."
        )
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
      }
      Spacer()
      Text(store.daemonStatus?.launchAgent.installed == true ? "Persistent" : "Manual")
        .font(.caption.bold())
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(HarnessTheme.accent(for: themeStyle), in: Capsule())
        .foregroundStyle(.white)
    }
  }

  private var onboardingStepsSection: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 200,
      maximumColumns: 3,
      spacing: 14
    ) {
      onboardingStep(
        title: "1. Start the daemon",
        detail: "Boot the local HTTP and SSE bridge.",
        isReady: store.connectionState == .online
      ) {
        HarnessAsyncActionButton(
          title: "Start Daemon",
          tint: store.connectionState == .online
            ? HarnessTheme.ink
            : HarnessTheme.accent(for: themeStyle),
          variant: store.connectionState == .online
            ? .bordered : .prominent,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.start",
          fillsWidth: false
        ) {
          await store.startDaemon()
        }
        .disabled(store.connectionState == .online)
        .focusable(store.connectionState != .online)
      }
      onboardingStep(
        title: "2. Install launchd",
        detail: "Keep the daemon available across app restarts.",
        isReady: store.daemonStatus?.launchAgent.installed == true
      ) {
        HarnessAsyncActionButton(
          title: "Install Launch Agent",
          tint: HarnessTheme.ink,
          variant: .bordered,
          isLoading: isLoading,
          accessibilityIdentifier: "harness.board.action.install",
          fillsWidth: false
        ) {
          await store.installLaunchAgent()
        }
        .disabled(store.daemonStatus?.launchAgent.installed == true)
        .focusable(store.daemonStatus?.launchAgent.installed != true)
      }
      onboardingStep(
        title: "3. Start a harness session",
        detail: "Sessions appear here as soon as the daemon indexes them.",
        isReady: !store.sessions.isEmpty
      ) {
        HarnessAsyncActionButton(
          title: "Refresh Index",
          tint: HarnessTheme.ink,
          variant: .bordered,
          isLoading: store.isRefreshing,
          accessibilityIdentifier: "harness.board.action.refresh",
          fillsWidth: false
        ) {
          await store.refresh()
        }
      }
    }
  }

  private func onboardingStep<Action: View>(
    title: String,
    detail: String,
    isReady: Bool,
    @ViewBuilder action: () -> Action
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top) {
        HStack {
          Circle()
            .fill(isReady ? HarnessTheme.success : HarnessTheme.caution)
            .frame(width: 10, height: 10)
            .accessibilityHidden(true)
          Text(title)
            .font(.system(.headline, design: .rounded, weight: .semibold))
        }
        Spacer()
        Text(isReady ? "Ready" : "Pending")
          .font(.caption.bold())
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(isReady ? HarnessTheme.success : HarnessTheme.caution, in: Capsule())
          .foregroundStyle(.white)
      }
      Text(detail)
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
        .lineLimit(2)
      Spacer(minLength: 0)
      action()
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(11)
    .harnessInsetPanel(cornerRadius: 18, fillOpacity: 0.05, strokeOpacity: isReady ? 0 : 0.50)
    .overlay {
      if isReady {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(HarnessTheme.success.opacity(0.04))
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(HarnessTheme.success.opacity(0.50), lineWidth: 1)
          }
      }
    }
    .opacity(isReady ? 0.65 : 1)
  }
}
