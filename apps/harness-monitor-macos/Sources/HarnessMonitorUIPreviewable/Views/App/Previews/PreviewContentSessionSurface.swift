import HarnessMonitorKit
import SwiftUI

#Preview("Session Content - Dashboard") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .dashboardLoaded)

  SessionContentContainer(
    store: store,
    dashboardUI: store.contentUI.dashboard,
    state: .init(
      detail: nil,
      summary: nil,
      timeline: [],
      timelineWindow: nil,
      tuiStatusByAgent: [:],
      isSessionStatusStale: false,
      isSessionReadOnly: false,
      isSelectionLoading: false,
      isTimelineLoading: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}

#Preview("Session Content - Cockpit") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)

  SessionContentContainer(
    store: store,
    dashboardUI: store.contentUI.dashboard,
    state: .init(
      detail: store.selectedSession,
      summary: store.selectedSessionSummary,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      tuiStatusByAgent: [:],
      isSessionStatusStale: false,
      isSessionReadOnly: false,
      isSelectionLoading: false,
      isTimelineLoading: false,
      isExtensionsLoading: false
    )
  )
  .frame(width: 980, height: 720)
}
