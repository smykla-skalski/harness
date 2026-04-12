import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice

  init(
    store: HarnessMonitorStore,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    self.store = store
    self.sessionCatalog = sessionCatalog
  }

  var body: some View {
    HarnessMonitorColumnScrollView(constrainContentWidth: true) {
      VStack(alignment: .leading, spacing: 24) {
        SessionsBoardRecentSessionsSection(
          sessions: sessionCatalog.recentSessions,
          selectSession: selectSession
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionsBoardRoot)
  }

  private func selectSession(_ sessionID: String) {
    Task { await store.selectSession(sessionID) }
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
