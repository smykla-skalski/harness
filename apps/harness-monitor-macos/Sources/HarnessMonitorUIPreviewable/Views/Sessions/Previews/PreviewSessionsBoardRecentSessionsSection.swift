import HarnessMonitorKit
import SwiftUI

#Preview("Recent sessions") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionsBoardRecentSessionsSection(
    store: store,
    sessions: PreviewFixtures.overflowSessions
  )
  .padding()
  .frame(width: 960)
}
