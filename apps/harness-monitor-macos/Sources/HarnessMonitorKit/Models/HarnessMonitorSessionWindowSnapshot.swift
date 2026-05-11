import Foundation

public enum HarnessMonitorSessionWindowSnapshotSource: String, Sendable {
  case live
  case cache
  case catalog
}

public enum HarnessMonitorSessionWindowTranscriptSource: String, Sendable {
  case direct
  case derived
  case cache
}

public struct HarnessMonitorSessionWindowSnapshot: Equatable, Sendable {
  public let summary: SessionSummary
  public let detail: SessionDetail?
  public let acpAgents: [AcpAgentSnapshot]
  public let acpInspectSample: AcpInspectSample?
  public let timeline: [TimelineEntry]
  public let timelineEntriesByAgentID: [String: [TimelineEntry]]
  public let transcript: [TimelineEntry]
  public let transcriptEntriesByAgentID: [String: [TimelineEntry]]
  public let transcriptSource: HarnessMonitorSessionWindowTranscriptSource
  public let timelineWindow: TimelineWindowResponse?
  public let source: HarnessMonitorSessionWindowSnapshotSource

  public init(
    summary: SessionSummary,
    detail: SessionDetail?,
    acpAgents: [AcpAgentSnapshot] = [],
    acpInspectSample: AcpInspectSample? = nil,
    timeline: [TimelineEntry],
    transcript: [TimelineEntry] = [],
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource = .derived,
    timelineWindow: TimelineWindowResponse?,
    source: HarnessMonitorSessionWindowSnapshotSource
  ) {
    self.summary = summary
    self.detail = detail
    self.acpAgents = acpAgents
    self.acpInspectSample = acpInspectSample
    self.timeline = timeline
    timelineEntriesByAgentID = timeline.partitionedByAgentID()
    self.transcript = transcript
    transcriptEntriesByAgentID = transcript.partitionedByAgentID()
    self.transcriptSource = transcriptSource
    self.timelineWindow = timelineWindow
    self.source = source
  }

  public func timeline(forAgent agentID: String) -> [TimelineEntry] {
    timelineEntriesByAgentID[agentID] ?? []
  }

  public func transcript(forAgent agentID: String) -> [TimelineEntry] {
    transcriptEntriesByAgentID[agentID] ?? []
  }
}
