import Foundation

// Bridge the generated TimelineEntryWire to the rich hand TimelineEntry. The two are
// field-identical thin mirrors (the hand payload is already JSONValue), so the map is
// a straight pass-through - it exists so wire-decoded entries (e.g. the codex
// transcript) reach the hand model the rest of the app consumes.
extension TimelineEntry {
  init(wire: TimelineEntryWire) {
    self.init(
      entryId: wire.entryId,
      recordedAt: wire.recordedAt,
      kind: wire.kind,
      sessionId: wire.sessionId,
      agentId: wire.agentId,
      taskId: wire.taskId,
      summary: wire.summary,
      payload: wire.payload
    )
  }
}

// The /v1/daemon/log-level get/set response (level/filter thin mirror, generated into
// SummariesWireTypes); backs both endpoints on both transports.
extension LogLevelResponse {
  public init(wire: LogLevelResponseWire) {
    self.init(level: wire.level, filter: wire.filter)
  }
}

// Timeline pagination cursor + window response (timelineWindow endpoint). The counts narrow
// UInt -> Int; the cursors and entries fold through their nested maps.

extension TimelineCursor {
  init(wire: TimelineCursorWire) {
    self.init(recordedAt: wire.recordedAt, entryId: wire.entryId)
  }
}

// The SSE push envelope (stream parse path). Thin mirror; the hand model keeps its UI stableID.
extension StreamEvent {
  init(wire: StreamEventWire) {
    self.init(
      event: wire.event,
      recordedAt: wire.recordedAt,
      sessionId: wire.sessionId,
      payload: wire.payload
    )
  }
}

extension TimelineWindowResponse {
  init(wire: TimelineWindowResponseWire) {
    self.init(
      revision: wire.revision,
      totalCount: Int(wire.totalCount),
      windowStart: Int(wire.windowStart),
      windowEnd: Int(wire.windowEnd),
      hasOlder: wire.hasOlder,
      hasNewer: wire.hasNewer,
      oldestCursor: wire.oldestCursor.map(TimelineCursor.init(wire:)),
      newestCursor: wire.newestCursor.map(TimelineCursor.init(wire:)),
      entries: wire.entries.map { $0.map(TimelineEntry.init(wire:)) },
      unchanged: wire.unchanged
    )
  }
}
