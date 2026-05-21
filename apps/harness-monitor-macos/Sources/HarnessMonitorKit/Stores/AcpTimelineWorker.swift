import Foundation

struct AcpToolCallPhaseKey: Hashable {
  let rowID: String
  let status: String

  init(metadata: ToolCallTimelineEntryMetadata) {
    rowID = metadata.rowID
    status = metadata.status
  }
}

private enum AcpToolCallPhaseLocation {
  case current(String)
  case incoming(Int)
}

struct AcpTimelineEntriesOutput: Sendable {
  let entries: [TimelineEntry]
  let changed: Bool
}

struct AcpTranscriptHistoryPreparationOutput: Sendable {
  let historyEntries: [TimelineEntry]
  let historyChanged: Bool
  let liveEntries: [TimelineEntry]
  let liveChanged: Bool
}

actor AcpTimelineWorker {
  func merge(
    current: [TimelineEntry],
    incoming: [TimelineEntry]
  ) -> AcpTimelineEntriesOutput {
    let entries = HarnessMonitorStore.mergedTimelineEntries(current, with: incoming)
    return AcpTimelineEntriesOutput(entries: entries, changed: entries != current)
  }

  func mergeTranscript(
    currentEntries: [TimelineEntry],
    historyEntries: [TimelineEntry],
    incoming liveEntries: [TimelineEntry]
  ) -> AcpTimelineEntriesOutput {
    let entries = HarnessMonitorStore.mergedTimelineEntries(historyEntries, with: liveEntries)
    return AcpTimelineEntriesOutput(entries: entries, changed: entries != currentEntries)
  }

  func mergeAndReattribute(
    current: [TimelineEntry],
    incoming: [TimelineEntry],
    using snapshots: [AcpAgentSnapshot]
  ) -> AcpTimelineEntriesOutput {
    let entries = HarnessMonitorStore.reattributedAcpEntries(
      HarnessMonitorStore.mergedTimelineEntries(current, with: incoming),
      using: snapshots
    )
    return AcpTimelineEntriesOutput(entries: entries, changed: entries != current)
  }

  func reattribute(
    _ entries: [TimelineEntry],
    using snapshots: [AcpAgentSnapshot]
  ) -> AcpTimelineEntriesOutput {
    let updated = HarnessMonitorStore.reattributedAcpEntries(entries, using: snapshots)
    return AcpTimelineEntriesOutput(entries: updated, changed: updated != entries)
  }

  func prepareTranscriptHistory(
    currentHistoryEntries: [TimelineEntry],
    responseEntries: [TimelineEntry],
    liveEntries: [TimelineEntry],
    using snapshots: [AcpAgentSnapshot]
  ) -> AcpTranscriptHistoryPreparationOutput {
    let historyEntries = HarnessMonitorStore.reattributedAcpEntries(
      responseEntries.filter(\.isAcpTranscriptResponseEntry),
      using: snapshots
    )
    let historyEntryIDs = Set(historyEntries.map(\.entryId))
    let updatedLiveEntries = liveEntries.filter { !historyEntryIDs.contains($0.entryId) }
    return AcpTranscriptHistoryPreparationOutput(
      historyEntries: historyEntries,
      historyChanged: historyEntries != currentHistoryEntries,
      liveEntries: updatedLiveEntries,
      liveChanged: updatedLiveEntries != liveEntries
    )
  }

  func partitionByAgentID(
    _ entries: [TimelineEntry]
  ) -> [String: [TimelineEntry]] {
    entries.partitionedByAgentID()
  }

  func waitForIdle() async {}
}
