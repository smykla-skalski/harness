import Foundation

public enum HarnessMonitorSessionWindowSnapshotSource: String, Sendable {
  case live
  case cache
  case catalog
}

public struct HarnessMonitorSessionWindowSnapshot: Equatable, Sendable {
  public let summary: SessionSummary
  public let detail: SessionDetail?
  public let timeline: [TimelineEntry]
  public let timelineEntriesByAgentID: [String: [TimelineEntry]]
  public let timelineWindow: TimelineWindowResponse?
  public let source: HarnessMonitorSessionWindowSnapshotSource

  public init(
    summary: SessionSummary,
    detail: SessionDetail?,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    source: HarnessMonitorSessionWindowSnapshotSource
  ) {
    self.summary = summary
    self.detail = detail
    self.timeline = timeline
    timelineEntriesByAgentID = timeline.partitionedByAgentID()
    self.timelineWindow = timelineWindow
    self.source = source
  }

  public func timeline(forAgent agentID: String) -> [TimelineEntry] {
    timelineEntriesByAgentID[agentID] ?? []
  }
}
