import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  @Bindable var sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  @Bindable var contentUI: HarnessMonitorStore.ContentUISlice
  @AppStorage("harnessMonitor.board.onboardingDismissed")
  private var isOnboardingDismissed = false

  init(
    store: HarnessMonitorStore,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    contentUI: HarnessMonitorStore.ContentUISlice
  ) {
    self.store = store
    self.sessionCatalog = sessionCatalog
    self.contentUI = contentUI
  }

  private var isLoading: Bool {
    contentUI.isBusy || contentUI.isRefreshing || contentUI.connectionState == .connecting
  }

  var body: some View {
    HarnessMonitorColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        if !isOnboardingDismissed {
          SessionsBoardOnboardingCard(
            connectionState: contentUI.connectionState,
            isLaunchAgentInstalled: contentUI.isLaunchAgentInstalled,
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
    contentUI: store.contentUI
  )
    .frame(width: 980, height: 720)
}

#Preview("Sessions Board - Empty") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .empty)

  SessionsBoardView(
    store: store,
    sessionCatalog: store.sessionIndex.catalog,
    contentUI: store.contentUI
  )
    .frame(width: 980, height: 720)
}
