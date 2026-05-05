import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

func makeTimelineEntries(
  count: Int,
  startingAt startIndex: Int = 0
) -> [TimelineEntry] {
  (0..<count).map { index in
    let entryIndex = startIndex + index
    return TimelineEntry(
      entryId: "timeline-entry-\(entryIndex)",
      recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - entryIndex),
      kind: "task_checkpoint",
      sessionId: "sess-pagination",
      agentId: "worker-pagination",
      taskId: nil,
      summary: "Timeline entry \(entryIndex)",
      payload: .object([:])
    )
  }
}

func makeTimelineEntry(
  kind: String,
  agentID: String,
  summary: String
) -> TimelineEntry {
  TimelineEntry(
    entryId: "timeline-entry-\(kind)-\(agentID)",
    recordedAt: "2026-04-14T10:00:00Z",
    kind: kind,
    sessionId: "session-1",
    agentId: agentID,
    taskId: nil,
    summary: summary,
    payload: .object([:])
  )
}

func makeTimelineRows(count: Int) -> [SessionTimelineRow] {
  (0..<count).map { index in
    let node = SessionTimelineNode(
      identity: .entry("timeline-entry-\(index)"),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: TimeInterval(1_900_000_000 - index)),
      rawTimestamp: nil,
      sourceLabel: "worker-pagination",
      title: "Timeline entry \(index)",
      detail: index.isMultiple(of: 2) ? "Detailed event payload \(index)" : nil,
      eventTone: .info,
      decision: nil
    )
    return SessionTimelineRow(
      node: node,
      dayDividerLabel: index == 12 ? "14 Apr" : nil,
      timestampLabel: "10:\(String(format: "%02d", index)):00",
      accessibilityTimestampLabel: "14 Apr 10:\(String(format: "%02d", index)):00",
      accessibilityLabel: "Event \(index)"
    )
  }
}

func makeWindow(
  entries: [TimelineEntry],
  windowStart: Int,
  windowEnd: Int,
  hasOlder: Bool,
  hasNewer: Bool
) -> TimelineWindowResponse {
  TimelineWindowResponse(
    revision: Int64(windowStart + windowEnd),
    totalCount: 32,
    windowStart: windowStart,
    windowEnd: windowEnd,
    hasOlder: hasOlder,
    hasNewer: hasNewer,
    oldestCursor: entries.last.map {
      TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
    },
    newestCursor: entries.first.map {
      TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
    },
    entries: nil,
    unchanged: false
  )
}

func makeCustomTimelineRow(
  id: String,
  title: String,
  detail: String? = nil
) -> SessionTimelineRow {
  SessionTimelineRow(
    node: SessionTimelineNode(
      identity: .entry(id),
      kind: .event,
      timestamp: Date(timeIntervalSince1970: 1_900_000_000),
      rawTimestamp: nil,
      sourceLabel: "worker-pagination",
      title: title,
      detail: detail,
      eventTone: .info,
      decision: nil
    ),
    dayDividerLabel: nil,
    timestampLabel: "10:00:00",
    accessibilityTimestampLabel: "14 Apr 10:00:00",
    accessibilityLabel: title
  )
}
