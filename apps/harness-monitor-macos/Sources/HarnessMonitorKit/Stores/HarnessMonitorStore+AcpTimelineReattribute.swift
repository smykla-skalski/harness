import Foundation

extension HarnessMonitorStore {
  func reattributedAcpEntries(
    _ entries: [TimelineEntry],
    using snapshots: [AcpAgentSnapshot]
  ) -> [TimelineEntry] {
    Self.reattributedAcpEntries(entries, using: snapshots)
  }

  nonisolated static func reattributedAcpEntries(
    _ entries: [TimelineEntry],
    using snapshots: [AcpAgentSnapshot]
  ) -> [TimelineEntry] {
    let identitiesByAcpID = Dictionary(
      uniqueKeysWithValues: snapshots.map { snapshot in
        (
          snapshot.managedAgentID,
          (sessionAgentID: snapshot.sessionAgentID, displayName: snapshot.displayName)
        )
      }
    )
    let updatedTimeline = entries.map { entry in
      guard let metadata = entry.acpTimelineIdentityMetadata(),
        let identity = identitiesByAcpID[metadata.acpAgentID]
      else {
        return entry
      }
      let identityChanged =
        entry.agentId != identity.sessionAgentID
        || metadata.sessionAgentID != identity.sessionAgentID
        || metadata.agentDisplayName != identity.displayName
      guard identityChanged
      else {
        return entry
      }
      return entry.reattributedAcpTimelineEntry(
        sessionAgentID: identity.sessionAgentID,
        displayName: identity.displayName
      )
    }

    return mergedTimelineEntries([], with: updatedTimeline)
  }

  func replaceSelectedTimeline(_ updatedTimeline: [TimelineEntry]) {
    timeline = updatedTimeline
    let resolvedWindow = normalizedTimelineWindow(
      timelineWindow,
      loadedTimeline: updatedTimeline
    )
    timelineWindow = resolvedWindow
    guard let selectedSession else {
      return
    }
    scheduleSelectedSessionCacheWrite(
      selectedSession,
      timeline: updatedTimeline,
      timelineWindow: resolvedWindow
        ?? TimelineWindowResponse.fallbackMetadata(for: updatedTimeline)
    )
  }

  func replaceSelectedAcpTranscript(
    _ updatedTimeline: [TimelineEntry],
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource?
  ) {
    selectedAcpTranscriptSource = transcriptSource
    selectedAcpTranscriptEntries = updatedTimeline
    guard !suppressSelectedAcpTranscriptCacheWrite else {
      return
    }
    guard let selectedSession else {
      return
    }
    let currentTimeline = timeline
    let currentTimelineWindow =
      timelineWindow ?? TimelineWindowResponse.fallbackMetadata(for: currentTimeline)
    scheduleSelectedSessionCacheWrite(
      selectedSession,
      timeline: currentTimeline,
      transcript: updatedTimeline,
      transcriptSource: transcriptSource,
      timelineWindow: currentTimelineWindow
    )
  }

  public func waitForAcpTimelineIdle() async {
    while true {
      let pendingTasks = [
        acpTimelineSync.mergeTask,
        acpTimelineSync.transcriptMergeTask,
        acpTimelineSync.transcriptLiveMergeTask,
        acpTimelineSync.transcriptHistoryTask,
        acpTimelineSync.reattributeTask,
        acpTimelineSync.transcriptReattributeTask,
        acpTimelineSync.transcriptPartitionTask,
      ].compactMap(\.self)

      guard !pendingTasks.isEmpty else {
        await acpTimelineWorker.waitForIdle()
        return
      }

      for task in pendingTasks {
        await task.value
      }
    }
  }

  nonisolated static func timelineEntrySortKey(for entry: TimelineEntry)
    -> TimelineEntrySortKey
  {
    TimelineEntrySortKey(
      entry: entry,
      toolCallSequence: entry.toolCallTimelineEntryMetadata()?.sequence
    )
  }
}
