import HarnessKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  @Bindable var store: HarnessStore

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 22) {
        if store.sessions.isEmpty {
          onboardingCard
        }
        metricsSection
        recentSessionsSection
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .animation(.easeInOut(duration: 0.18), value: store.isRefreshing)
    .animation(.easeInOut(duration: 0.18), value: store.sessions)
    .foregroundStyle(HarnessTheme.ink)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sessionsBoardRoot)
  }

  private var onboardingCard: some View {
    VStack(alignment: .leading, spacing: 16) {
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
          .background(HarnessTheme.accent, in: Capsule())
          .foregroundStyle(.white)
      }

      onboardingStepsSection

      onboardingActionButtons
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.onboardingCard)
  }

  private var metricsSection: some View {
    HarnessGlassContainer(spacing: 16) {
      HarnessAdaptiveGridLayout(
        minimumColumnWidth: 160,
        maximumColumns: 4,
        spacing: 16
      ) {
        metricCards
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var metricCards: some View {
    trackedProjectsMetricCard
    indexedSessionsMetricCard
    openWorkMetricCard
    blockedMetricCard
  }

  private var recentSessionsSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Recent Sessions")
        .font(.system(.title3, design: .serif, weight: .semibold))
      if store.sessions.isEmpty {
        Text(
          "No sessions indexed yet. Bring the daemon online or refresh after starting a harness session."
        )
        .font(.system(.body, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
      } else {
        HarnessGlassContainer(spacing: 12) {
          ForEach(store.sessions.prefix(8)) { session in
            Button {
              select(sessionID: session.sessionId)
            } label: {
              HStack(alignment: .top, spacing: 14) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                  .fill(statusColor(for: session.status))
                  .frame(width: 10)
                VStack(alignment: .leading, spacing: 4) {
                  Text(session.context)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HarnessTheme.ink)
                    .multilineTextAlignment(.leading)
                  Text("\(session.projectName) • \(session.sessionId)")
                    .font(.caption.monospaced())
                    .foregroundStyle(HarnessTheme.secondaryInk)
                }
                Spacer()
                Text(formatTimestamp(session.updatedAt))
                  .font(.caption.weight(.semibold))
                  .foregroundStyle(HarnessTheme.secondaryInk)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(14)
              .background {
                HarnessInteractiveCardBackground(cornerRadius: 18, tint: nil)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.recentSessionsCard)
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(HarnessTheme.secondaryInk)
      Text(value)
        .font(.system(size: 34, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(minHeight: 80, contentPadding: 14)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.boardMetricCard(title))
  }

  private func onboardingStep(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Circle()
          .fill(isReady ? HarnessTheme.success : HarnessTheme.caution)
          .frame(width: 10, height: 10)
          .accessibilityHidden(true)
        Text(title)
          .font(.system(.headline, design: .rounded, weight: .semibold))
      }
      Text(detail)
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(HarnessTheme.secondaryInk)
        .lineLimit(2)
      Text(isReady ? "Ready" : "Pending")
        .font(.caption.bold())
        .foregroundStyle(isReady ? HarnessTheme.success : HarnessTheme.caution)
    }
    .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
    .padding(11)
    .background {
      HarnessInsetPanelBackground(
        cornerRadius: 18,
        fillOpacity: 0.05,
        strokeOpacity: 0.10
      )
    }
  }

  private var onboardingStepsSection: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 200,
      maximumColumns: 3,
      spacing: 14
    ) {
      onboardingDaemonStep
      onboardingLaunchdStep
      onboardingSessionStep
    }
  }

  private var onboardingDaemonStep: some View {
    onboardingStep(
      title: "1. Start the daemon",
      detail: "Boot the local HTTP and SSE bridge.",
      isReady: store.connectionState == .online
    )
  }

  private var onboardingLaunchdStep: some View {
    onboardingStep(
      title: "2. Install launchd",
      detail: "Keep the daemon available across app restarts.",
      isReady: store.daemonStatus?.launchAgent.installed == true
    )
  }

  private var onboardingSessionStep: some View {
    onboardingStep(
      title: "3. Start a harness session",
      detail: "Sessions appear here as soon as the daemon indexes them.",
      isReady: !store.sessions.isEmpty
    )
  }

  private var trackedProjectsMetricCard: some View {
    metricCard(
      title: "Tracked Projects",
      value: "\(store.projects.count)",
      tint: HarnessTheme.accent
    )
  }

  private var indexedSessionsMetricCard: some View {
    metricCard(
      title: "Indexed Sessions",
      value: "\(store.sessions.count)",
      tint: HarnessTheme.success
    )
  }

  private var openWorkMetricCard: some View {
    metricCard(
      title: "Open Work",
      value: "\(store.totalOpenWorkCount)",
      tint: HarnessTheme.warmAccent
    )
  }

  private var blockedMetricCard: some View {
    metricCard(
      title: "Blocked",
      value: "\(store.totalBlockedCount)",
      tint: HarnessTheme.danger
    )
  }

  private func select(sessionID: String) {
    store.primeSessionSelection(sessionID)
    Task {
      await store.selectSession(sessionID)
    }
  }
}

extension SessionsBoardView {
  @ViewBuilder fileprivate var onboardingActionButtons: some View {
    HarnessGlassContainer(spacing: 10) {
      HarnessWrapLayout(spacing: 10, lineSpacing: 10) {
        startDaemonButton
        installLaunchAgentButton
        refreshIndexButton
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  fileprivate var startDaemonButton: some View {
    HarnessAsyncActionButton(
      title: "Start Daemon",
      tint: HarnessTheme.accent,
      variant: .prominent,
      isLoading: isLoading,
      accessibilityIdentifier: "harness.board.action.start",
      fillsWidth: false
    ) {
      await store.startDaemon()
    }
  }

  fileprivate var installLaunchAgentButton: some View {
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
  }

  fileprivate var refreshIndexButton: some View {
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
