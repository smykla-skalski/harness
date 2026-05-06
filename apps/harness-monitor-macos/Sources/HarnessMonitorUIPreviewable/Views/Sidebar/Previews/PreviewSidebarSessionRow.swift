import HarnessMonitorKit
import SwiftUI

#Preview("Sidebar row") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  VStack(spacing: HarnessMonitorTheme.sectionSpacing) {
    SidebarSessionRow(
      session: PreviewFixtures.summary,
      presentation: store.sessionSummaryPresentation(for: PreviewFixtures.summary),
      isBookmarked: true,
      lastActivityText: formatTimestamp(PreviewFixtures.summary.lastActivityAt),
      fontScale: 1
    )
    .padding()

    let overflowSession = PreviewFixtures.overflowSessions[3]
    SidebarSessionRow(
      session: overflowSession,
      presentation: store.sessionSummaryPresentation(for: overflowSession),
      isBookmarked: false,
      lastActivityText: formatTimestamp(overflowSession.lastActivityAt),
      fontScale: 1
    )
    .padding()
  }
  .padding()
  .frame(width: 360)
}
