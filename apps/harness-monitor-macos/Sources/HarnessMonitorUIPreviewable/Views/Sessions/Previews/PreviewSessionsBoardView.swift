import HarnessMonitorKit
import SwiftUI

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
