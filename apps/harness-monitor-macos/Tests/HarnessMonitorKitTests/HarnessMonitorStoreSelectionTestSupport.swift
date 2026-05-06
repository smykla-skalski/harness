@testable import HarnessMonitorKit

enum HarnessMonitorStoreSelectionTestSupport {
  static func configuredClient(
    summaries: [SessionSummary],
    detailsByID: [String: SessionDetail],
    timelinesBySessionID: [String: [TimelineEntry]] = [:],
    detail: SessionDetail
  ) -> RecordingHarnessClient {
    let client = RecordingHarnessClient(detail: detail)
    client.configureSessions(
      summaries: summaries,
      detailsByID: detailsByID,
      timelinesBySessionID: timelinesBySessionID
    )
    return client
  }

  @MainActor
  static func initialTimelineWindowSize(for totalCount: Int) -> Int {
    min(HarnessMonitorStore.initialSelectedTimelineWindowLimit, totalCount)
  }

  @MainActor
  static func timelineRefreshLimit(loadedCount: Int) -> Int {
    max(HarnessMonitorStore.initialSelectedTimelineWindowLimit, loadedCount)
  }
}
