import HarnessKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessStore
  @ScaledMetric(relativeTo: .caption)
  private var barWidth: CGFloat = 12
  @ScaledMetric(relativeTo: .largeTitle)
  private var cardMinHeight: CGFloat = 68

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        if store.sessions.isEmpty {
          SessionsBoardOnboardingCard(
            connectionState: store.connectionState,
            isLaunchAgentInstalled: store.daemonStatus?.launchAgent.installed == true,
            hasSessions: !store.sessions.isEmpty,
            isLoading: isLoading,
            startDaemon: startDaemon,
            installLaunchAgent: installLaunchAgent,
            refresh: refresh
          )
        }
        metricsSection
        SessionsBoardRecentSessionsSection(
          sessions: store.sessions,
          selectSession: selectSession
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.sessionsBoardRoot)
  }

  private var metricsSection: some View {
    HarnessAdaptiveGridLayout(
      minimumColumnWidth: 160,
      maximumColumns: 4,
      spacing: 16
    ) {
      metricCards
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder private var metricCards: some View {
    metricCard(
      title: "Tracked Projects",
      value: "\(store.projects.count)",
      tint: HarnessTheme.accent
    )
    metricCard(
      title: "Indexed Sessions",
      value: "\(store.sessions.count)",
      tint: HarnessTheme.success
    )
    metricCard(
      title: "Open Work",
      value: "\(store.totalOpenWorkCount)",
      tint: HarnessTheme.warmAccent
    )
    metricCard(
      title: "Blocked",
      value: "\(store.totalBlockedCount)",
      tint: HarnessTheme.danger
    )
  }

  private func metricCard(title: String, value: String, tint: Color) -> some View {
    HStack(alignment: .top, spacing: HarnessTheme.sectionSpacing) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: barWidth)
        .frame(minHeight: cardMinHeight)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: HarnessTheme.itemSpacing) {
        Text(title.uppercased())
          .scaledFont(.caption.weight(.semibold))
          .tracking(HarnessTheme.uppercaseTracking)
          .foregroundStyle(HarnessTheme.secondaryInk)
        Text(value)
          .scaledFont(.system(.largeTitle, design: .rounded, weight: .heavy))
          .foregroundStyle(tint)
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, HarnessTheme.itemSpacing)
    .accessibilityElement(children: .combine)
    .accessibilityTestProbe(
      HarnessAccessibility.boardMetricCard(title),
      label: title,
      value: value
    )
  }

  private func selectSession(_ sessionID: String) {
    store.primeSessionSelection(sessionID)
    Task {
      await store.selectSession(sessionID)
    }
  }

  private func startDaemon() async {
    await store.startDaemon()
  }

  private func installLaunchAgent() async {
    await store.installLaunchAgent()
  }

  private func refresh() async {
    await store.refresh()
  }
}
