import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @AppStorage("harnessMonitor.board.onboardingDismissed")
  private var isOnboardingDismissed = false

  init(
    store: HarnessMonitorStore,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    self.store = store
    self.sessionCatalog = sessionCatalog
    self.dashboardUI = dashboardUI
  }

  private var isLoading: Bool {
    dashboardUI.isBusy
      || dashboardUI.isRefreshing
      || dashboardUI.connectionState == .connecting
  }

  var body: some View {
    HarnessMonitorColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        if !isOnboardingDismissed {
          SessionsBoardOnboardingCard(
            connectionState: dashboardUI.connectionState,
            isLaunchAgentInstalled: dashboardUI.isLaunchAgentInstalled,
            hasSessions: !sessionCatalog.recentSessions.isEmpty,
            isLoading: isLoading,
            startDaemon: startDaemon,
            installLaunchAgent: installLaunchAgent,
            refresh: refresh,
            dismiss: { isOnboardingDismissed = true }
          )
        }
        SessionsBoardRecentSessionsSection(
          sessions: sessionCatalog.recentSessions,
          selectSession: selectSession
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionsBoardRoot)
  }

  private func selectSession(_ sessionID: String) {
    Task { await store.selectSession(sessionID) }
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

#Preview("Sessions Board - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionsBoardView(
    store: store,
    sessionCatalog: store.sessionIndex.catalog,
    dashboardUI: store.contentUI.dashboard
  )
  .frame(width: 980, height: 720)
}

#Preview("Sessions Board - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)

  SessionsBoardView(
    store: store,
    sessionCatalog: store.sessionIndex.catalog,
    dashboardUI: store.contentUI.dashboard
  )
  .frame(width: 980, height: 720)
}
