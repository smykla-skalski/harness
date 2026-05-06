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
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionsBoardScrollView,
      scrollSurfaceLabel: "Sessions board"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        SessionsBoardRecentSessionsSection(
          store: store,
          sessions: sessionCatalog.recentSessions
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionsBoardRoot)
    .task {
      HarnessMonitorUITestTrace.record(
        component: "sessions.board",
        event: "mounted",
        details: [
          "recent_session_count": String(sessionCatalog.recentSessions.count),
          "selected_session_id": store.selectedSessionID ?? "nil",
        ]
      )
    }
  }

}
