import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let primaryContentFocusScope: Namespace.ID?
  let primaryContentPagingResponderRequest: Int
  let prefersPrimaryContentFocus: Bool
  let primaryContentPagingResponderEnabled: Bool

  init(
    store: HarnessMonitorStore,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice,
    primaryContentFocusScope: Namespace.ID? = nil,
    primaryContentPagingResponderRequest: Int = 0,
    prefersPrimaryContentFocus: Bool = false,
    primaryContentPagingResponderEnabled: Bool = false
  ) {
    self.store = store
    self.sessionCatalog = sessionCatalog
    self.primaryContentFocusScope = primaryContentFocusScope
    self.primaryContentPagingResponderRequest = primaryContentPagingResponderRequest
    self.prefersPrimaryContentFocus = prefersPrimaryContentFocus
    self.primaryContentPagingResponderEnabled = primaryContentPagingResponderEnabled
  }

  var body: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionsBoardScrollView,
      scrollSurfaceLabel: "Sessions board",
      primaryFocusScope: primaryContentFocusScope,
      prefersDefaultFocus: prefersPrimaryContentFocus,
      pagingResponderRequest: primaryContentPagingResponderRequest,
      pagingResponderEnabled: primaryContentPagingResponderEnabled
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
