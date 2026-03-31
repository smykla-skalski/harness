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
        }
        metricsSection
        SessionsBoardRecentSessionsSection(sessions: store.sessions, store: store)
      }
      .animation(.spring(duration: 0.3), value: store.sessions)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(.primary)
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
    .animation(.spring(duration: 0.3), value: store.projects.count)
    metricCard(
      title: "Indexed Sessions",
      value: "\(store.sessions.count)",
      tint: HarnessTheme.success
    )
    .animation(.spring(duration: 0.3), value: store.sessions.count)
    metricCard(
      title: "Open Work",
      value: "\(store.totalOpenWorkCount)",
      tint: HarnessTheme.warmAccent
    )
    .animation(.spring(duration: 0.3), value: store.totalOpenWorkCount)
    metricCard(
      title: "Blocked",
      value: "\(store.totalBlockedCount)",
      tint: HarnessTheme.danger
    )
    .animation(.spring(duration: 0.3), value: store.totalBlockedCount)
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
          .font(.system(.largeTitle, design: .rounded, weight: .heavy))
          .foregroundStyle(tint)
          .contentTransition(.numericText())
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 8)
    .accessibilityTestProbe(
      HarnessAccessibility.boardMetricCard(title),
      label: title,
      value: value
    )
  }

}
