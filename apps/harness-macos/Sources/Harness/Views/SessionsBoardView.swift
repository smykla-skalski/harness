import HarnessKit
import Observation
import SwiftUI

struct SessionsBoardView: View {
  @Environment(\.harnessThemeStyle)
  private var themeStyle
  @Environment(\.isInsideGlassEffect)
  private var isInsideGlassEffect
  @Bindable var store: HarnessStore

  private var metricCardGlassState: String {
    let isGradient = HarnessTheme.usesGradientChrome(for: themeStyle)
    if !isGradient { return "glass=flat" }
    if isInsideGlassEffect {
      let fill = effectiveSuppressedGlassFill(0.10)
      return "glass=suppressed, fill=\(String(format: "%.2f", fill))"
    }
    return "glass=active"
  }

  private var isLoading: Bool {
    store.isDaemonActionInFlight || store.isRefreshing || store.connectionState == .connecting
  }

  var body: some View {
    HarnessColumnScrollView {
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
    metricCard(
      title: "Tracked Projects",
      value: "\(store.projects.count)",
      tint: HarnessTheme.accent(for: themeStyle)
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
    let useGradientChrome = HarnessTheme.usesGradientChrome(for: themeStyle)
    let plaqueFill =
      useGradientChrome
      ? HarnessTheme.surface(for: themeStyle).opacity(0.18)
      : HarnessTheme.surfaceHover(for: themeStyle).opacity(0.96)
    let plaqueStroke =
      useGradientChrome
      ? Color.white.opacity(0.10)
      : HarnessTheme.panelBorder(for: themeStyle).opacity(0.24)

    return HStack(alignment: .top, spacing: 14) {
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
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(plaqueFill)
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .stroke(plaqueStroke, lineWidth: 1)
          }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .harnessCard(minHeight: 80, contentPadding: 14)
    .overlay {
      AccessibilityTextMarker(
        identifier: HarnessAccessibility.boardMetricGlassState(title),
        text: metricCardGlassState
      )
    }
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
