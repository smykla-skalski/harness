import HarnessKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessStore

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 22) {
        if store.sessions.isEmpty {
          SessionsBoardOnboardingCard(store: store, isLoading: isLoading)
            .animation(.spring(duration: 0.3), value: isLoading)
            .animation(.spring(duration: 0.3), value: store.connectionState)
        }
        metricsSection
          .animation(.spring(duration: 0.3), value: store.sessions)
        SessionsBoardRecentSessionsSection(sessions: store.sessions, onSelect: select)
          .animation(.spring(duration: 0.3), value: store.sessions)
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
    HStack(alignment: .top, spacing: 14) {
      RoundedRectangle(cornerRadius: 999, style: .continuous)
        .fill(tint)
        .frame(width: 12)
        .frame(minHeight: 68)
        .accessibilityHidden(true)
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessAccessibility.boardMetricCard(title))
  }

  private func select(sessionID: String) {
    store.primeSessionSelection(sessionID)
    Task {
      await store.selectSession(sessionID)
    }
  }
}
