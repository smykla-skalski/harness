import HarnessMonitorKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  @Bindable var store: MonitorStore

  private var isLoading: Bool {
    store.isBusy || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    MonitorColumnScrollView {
      VStack(alignment: .leading, spacing: 22) {
        hero
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
    .foregroundStyle(MonitorTheme.ink)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.sessionsBoardRoot)
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Harness Monitor")
        .font(.system(size: 42, weight: .black, design: .serif))
      Text(
        "A live control deck for harness daemon sessions, task flow, runtimes, and signal latency."
      )
      .font(.system(.title3, design: .rounded, weight: .medium))
      .foregroundStyle(.secondary)

      if store.isRefreshing || store.connectionState == .connecting {
        MonitorLoadingStateView(title: loadingTitle)
          .transition(.move(edge: .top).combined(with: .opacity))
      }

      if let lastError = store.lastError {
        Text(lastError)
          .font(.system(.footnote, design: .rounded, weight: .semibold))
          .foregroundStyle(MonitorTheme.danger)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(contentPadding: 16)
  }

  private var onboardingCard: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
          Label("Bring The Monitor Online", systemImage: "dot.radiowaves.left.and.right")
            .font(.system(.title3, design: .rounded, weight: .bold))
          Text(
            "Harness Monitor only reads live state from the local daemon. "
              + "Start the control plane once, then keep it resident with a launch agent."
          )
          .font(.system(.body, design: .rounded, weight: .medium))
          .foregroundStyle(.secondary)
        }
        Spacer()
        Text(store.daemonStatus?.launchAgent.installed == true ? "Persistent" : "Manual")
          .font(.caption.bold())
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .background(MonitorTheme.accent, in: Capsule())
          .foregroundStyle(.white)
      }

      onboardingStepsSection

      onboardingActionButtons
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.onboardingCard)
  }

  private var metricsSection: some View {
    MonitorAdaptiveGridLayout(
      minimumColumnWidth: 140,
      maximumColumns: 4,
      spacing: 16
    ) {
      metricCards
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var metricCards: some View {
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
        .foregroundStyle(.secondary)
      } else {
        ForEach(store.sessions.prefix(8)) { session in
          Button {
            Task {
              await store.selectSession(session.sessionId)
            }
          } label: {
            HStack(alignment: .top, spacing: 14) {
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(statusColor(for: session.status))
                .frame(width: 10)
              VStack(alignment: .leading, spacing: 4) {
                Text(session.context)
                  .font(.system(.headline, design: .rounded, weight: .semibold))
                  .multilineTextAlignment(.leading)
                Text("\(session.projectName) • \(session.sessionId)")
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
              }
              Spacer()
              Text(formatTimestamp(session.updatedAt))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(contentPadding: 16)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.recentSessionsCard)
  }

  private var loadingTitle: String {
    switch store.connectionState {
    case .connecting:
      "Connecting to the live daemon stream"
    default:
      "Refreshing the indexed session board"
    }
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 34, weight: .heavy, design: .rounded))
        .foregroundStyle(tint)
        .contentTransition(.numericText())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .monitorCard(minHeight: 76, contentPadding: 14)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(MonitorAccessibility.boardMetricCard(title))
  }

  private func onboardingStep(
    title: String,
    detail: String,
    isReady: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Circle()
          .fill(isReady ? MonitorTheme.success : MonitorTheme.caution)
          .frame(width: 10, height: 10)
        Text(title)
          .font(.system(.headline, design: .rounded, weight: .semibold))
      }
      Text(detail)
        .font(.system(.footnote, design: .rounded, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(2)
      Text(isReady ? "Ready" : "Pending")
        .font(.caption.bold())
        .foregroundStyle(isReady ? MonitorTheme.success : MonitorTheme.caution)
    }
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
    .padding(11)
    .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 18))
  }

  private var onboardingStepsSection: some View {
    MonitorAdaptiveGridLayout(
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
      tint: MonitorTheme.accent
    )
  }

  private var indexedSessionsMetricCard: some View {
    metricCard(
      title: "Indexed Sessions",
      value: "\(store.sessions.count)",
      tint: MonitorTheme.success
    )
  }

  private var openWorkMetricCard: some View {
    metricCard(
      title: "Open Work",
      value: "\(store.sessions.reduce(0) { $0 + $1.metrics.openTaskCount })",
      tint: MonitorTheme.warmAccent
    )
  }

  private var blockedMetricCard: some View {
    metricCard(
      title: "Blocked",
      value: "\(store.sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount })",
      tint: MonitorTheme.danger
    )
  }

  @ViewBuilder
  private var onboardingActionButtons: some View {
    MonitorAdaptiveGridLayout(
      minimumColumnWidth: 154,
      maximumColumns: 3,
      spacing: 12
    ) {
      MonitorAsyncActionButton(
        title: "Start Daemon",
        tint: MonitorTheme.accent,
        variant: .prominent,
        isLoading: isLoading,
        accessibilityIdentifier: "monitor.board.action.start",
        fillsWidth: true
      ) {
        await store.startDaemon()
      }

      MonitorAsyncActionButton(
        title: "Install Launch Agent",
        tint: MonitorTheme.ink,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: "monitor.board.action.install",
        fillsWidth: true
      ) {
        await store.installLaunchAgent()
      }

      MonitorAsyncActionButton(
        title: "Refresh Index",
        tint: MonitorTheme.ink,
        variant: .bordered,
        isLoading: isLoading,
        accessibilityIdentifier: "monitor.board.action.refresh",
        fillsWidth: true
      ) {
        await store.refresh()
      }
    }
  }
}
