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
    self.timelineWindow = timelineWindow
    self.source = source
  }
}
