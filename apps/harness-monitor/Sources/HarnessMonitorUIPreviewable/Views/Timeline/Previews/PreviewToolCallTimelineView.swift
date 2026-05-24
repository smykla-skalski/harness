import HarnessMonitorKit
import SwiftUI

#Preview("Tool Call Timeline") {
  ToolCallTimelineView(
    entries: PreviewFixtures.toolCallTimelineEntries,
    liveAnnouncementRowIDs: [PreviewFixtures.toolCallTimelineLiveRowID],
    overflowNotice: PreviewFixtures.toolCallTimelineOverflowNotice
  )
  .padding(16)
  .frame(width: 780)
}
