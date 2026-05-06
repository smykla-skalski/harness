import HarnessMonitorKit
import SwiftUI

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    tuiStatusByAgent: [:],
    isSessionStatusStale: false,
    isSessionReadOnly: false,
    isTimelineLoading: false,
    isExtensionsLoading: false
  )
}

#Preview("Cockpit - TUI agents") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .agentTuiOverflow),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    tuiStatusByAgent: [:],
    isSessionStatusStale: false,
    isSessionReadOnly: false,
    isTimelineLoading: false,
    isExtensionsLoading: false
  )
}
