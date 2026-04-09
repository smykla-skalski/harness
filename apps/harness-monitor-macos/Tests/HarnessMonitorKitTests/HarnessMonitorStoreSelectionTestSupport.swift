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
}
