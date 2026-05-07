import HarnessMonitorKit
import SwiftUI

#Preview("Sidebar row") {
  sidebarSessionRowPreview(displayMode: .strict)
}

#Preview("Sidebar row - Dense") {
  sidebarSessionRowPreview(displayMode: .dense)
}

@MainActor
private func sidebarSessionRowPreview(
  displayMode: HarnessMonitorSidebarSessionRowDisplayMode
) -> some View {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  return VStack(spacing: HarnessMonitorTheme.sectionSpacing) {
    SidebarSessionRow(
      session: PreviewFixtures.summary,
      presentation: store.sessionSummaryPresentation(for: PreviewFixtures.summary),
      isBookmarked: true,
      lastActivityText: formatTimestamp(PreviewFixtures.summary.lastActivityAt),
      fontScale: 1,
      displayMode: displayMode
    )
    .padding()

    let overflowSession = PreviewFixtures.overflowSessions[3]
    SidebarSessionRow(
      session: overflowSession,
      presentation: store.sessionSummaryPresentation(for: overflowSession),
      isBookmarked: false,
      lastActivityText: formatTimestamp(overflowSession.lastActivityAt),
      fontScale: 1,
      displayMode: displayMode
    )
    .padding()
  }
  .padding()
  .frame(width: 360)
}
