import HarnessMonitorKit
import SwiftUI

extension SessionCockpitTimelineSection {
  static var richPreview: some View {
    SessionCockpitTimelineSection(
      sessionID: PreviewFixtures.summary.sessionId,
      timeline: PreviewFixtures.richSessionTimeline,
      timelineWindow: PreviewFixtures.richSessionTimelineWindow,
      decisions: PreviewFixtures.richSessionTimelineDecisions,
      isTimelineLoading: false,
      store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
    )
    .padding()
    .frame(width: 960)
  }
}

#Preview("Timeline Cursor") {
  SessionCockpitTimelineSection(
    sessionID: PreviewFixtures.summary.sessionId,
    timeline: Array(PreviewFixtures.pagedTimeline.prefix(18)),
    timelineWindow: TimelineWindowResponse(
      revision: 1,
      totalCount: PreviewFixtures.pagedTimeline.count,
      windowStart: 0,
      windowEnd: 18,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: TimelineCursor(
        recordedAt: PreviewFixtures.pagedTimeline[17].recordedAt,
        entryId: PreviewFixtures.pagedTimeline[17].entryId
      ),
      newestCursor: TimelineCursor(
        recordedAt: PreviewFixtures.pagedTimeline[0].recordedAt,
        entryId: PreviewFixtures.pagedTimeline[0].entryId
      ),
      entries: nil,
      unchanged: false
    ),
    decisions: [],
    isTimelineLoading: false,
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
  )
  .padding()
  .frame(width: 960)
}
