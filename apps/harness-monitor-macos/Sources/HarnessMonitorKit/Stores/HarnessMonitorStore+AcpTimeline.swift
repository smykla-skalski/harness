import Foundation

extension HarnessMonitorStore {
  private struct TimelineEntrySortKey {
    let entry: TimelineEntry
    let toolCallSequence: UInt64?
  }

  static func acpInspectSampledAt(from recordedAt: String?) -> Date {
    parsedAcpInspectRecordedAt(recordedAt) ?? Date()
  }

  func acpToolCallTimelineMetadata(
    for payload: AcpEventBatchPayload
  ) -> AcpToolCallTimelineMetadata {
    let crosswalk = acpIdentityCrosswalk()
    let linkage = crosswalk.agentLinkage(
      forManagedAgentIdentity: payload.managedAgentIdentity
    )
    let fallbackSessionAgentIdentity = payload.events.lazy.compactMap(\.sessionAgentIdentity).first
    let fallbackSessionAgentID =
      fallbackSessionAgentIdentity?.rawValue
      ?? linkage?.explicitSessionAgentLookupKey
      ?? AcpAgentIdentityCrosswalk.explicitSessionAgentFallbackKey(
        for: payload.managedAgentIdentity
      )
    return AcpToolCallTimelineMetadata(
      managedAgentID: linkage?.managedAgentIdentity.rawValue
        ?? payload.managedAgentIdentity.rawValue,
      sessionAgentID: linkage?.sessionAgentIdentity?.rawValue ?? fallbackSessionAgentID,
      displayName: linkage?.explicitDisplayName
        ?? fallbackSessionAgentIdentity?.rawValue
        ?? AcpAgentIdentityCrosswalk.unresolvedDisplayName(for: payload.managedAgentIdentity),
      capabilityTags: linkage?.capabilityTags ?? []
    )
  }

  func mergedTimelineEntries(
    _ current: [TimelineEntry],
    with incoming: [TimelineEntry]
  ) -> [TimelineEntry] {
    Self.mergedTimelineEntries(current, with: incoming)
  }

  nonisolated static func mergedTimelineEntries(
    _ current: [TimelineEntry],
    with incoming: [TimelineEntry]
  ) -> [TimelineEntry] {
    let currentByEntryID = Dictionary(uniqueKeysWithValues: current.map { ($0.entryId, $0) })
    var phaseLocations: [AcpToolCallPhaseKey: AcpToolCallPhaseLocation] = [:]
    var replacementsByCurrentEntryID: [String: TimelineEntry] = [:]
    var normalizedIncoming: [TimelineEntry] = []

    for entry in current {
      guard let metadata = entry.toolCallTimelineEntryMetadata() else {
        continue
      }
      phaseLocations[AcpToolCallPhaseKey(metadata: metadata)] = .current(entry.entryId)
    }

    for entry in incoming {
      guard let metadata = entry.toolCallTimelineEntryMetadata() else {
        normalizedIncoming.append(entry)
        continue
      }
      let phaseKey = AcpToolCallPhaseKey(metadata: metadata)
      guard let existingLocation = phaseLocations[phaseKey] else {
        phaseLocations[phaseKey] = .incoming(normalizedIncoming.count)
        normalizedIncoming.append(entry)
        continue
      }

      HarnessMonitorLogger.store.warning(
        """
        Coalescing duplicate ACP tool call id \(phaseKey.rowID, privacy: .public) \
        for \(phaseKey.status, privacy: .public) before timeline merge
        """
      )

      switch existingLocation {
      case .current(let currentEntryID):
        let existingEntry =
          replacementsByCurrentEntryID[currentEntryID]
          ?? currentByEntryID[currentEntryID]
          ?? entry
        replacementsByCurrentEntryID[currentEntryID] = Self.preferredTimelineEntry(
          existingEntry,
          over: entry
        )
      case .incoming(let index):
        normalizedIncoming[index] = Self.preferredTimelineEntry(
          normalizedIncoming[index],
          over: entry
        )
      }
    }

    let normalizedCurrent = current.map { entry in
      replacementsByCurrentEntryID[entry.entryId] ?? entry
    }

    return Dictionary(grouping: normalizedCurrent + normalizedIncoming, by: \.entryId)
      .compactMap { _, entries in entries.last }
      .map(Self.timelineEntrySortKey(for:))
      .sorted(by: Self.timelineEntrySortOrder)
      .map(\.entry)
  }

  nonisolated private static func timelineEntrySortOrder(
    lhs: TimelineEntrySortKey,
    rhs: TimelineEntrySortKey
  ) -> Bool {
    if lhs.entry.recordedAt != rhs.entry.recordedAt {
      return lhs.entry.recordedAt > rhs.entry.recordedAt
    }
    if let lhsSequence = lhs.toolCallSequence,
      let rhsSequence = rhs.toolCallSequence,
      lhsSequence != rhsSequence
    {
      return lhsSequence > rhsSequence
    }
    return lhs.entry.entryId < rhs.entry.entryId
  }

  nonisolated static func preferredTimelineEntry(
    _ lhs: TimelineEntry,
    over rhs: TimelineEntry
  ) -> TimelineEntry {
    timelineEntrySortOrder(
      lhs: timelineEntrySortKey(for: lhs),
      rhs: timelineEntrySortKey(for: rhs)
    )
      ? lhs : rhs
  }

  nonisolated static func parsedAcpInspectRecordedAt(_ recordedAt: String?) -> Date? {
    guard let recordedAt else {
      return nil
    }
    return acpInspectRecordedAtFormatterFracSeconds.date(from: recordedAt)
      ?? acpInspectRecordedAtFormatter.date(from: recordedAt)
  }

  func rebuildAcpTranscriptPartition() {
    acpTranscriptPartitionTask?.cancel()
    acpTranscriptPartitionGeneration &+= 1
    let generation = acpTranscriptPartitionGeneration
    let entries = selectedAcpTranscriptEntries
    acpTranscriptPartitionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let partition = await self.acpTimelineWorker.partitionByAgentID(entries)
      guard !Task.isCancelled, self.acpTranscriptPartitionGeneration == generation else {
        return
      }
      self.acpTranscriptByAgentID = partition
      self.acpTranscriptPartitionTask = nil
    }
  }

  func rebuildSelectedAcpTranscriptEntries() {
    acpTranscriptMergeTask?.cancel()
    acpTranscriptMergeGeneration &+= 1
    let generation = acpTranscriptMergeGeneration
    let currentEntries = selectedAcpTranscriptEntries
    let historyEntries = selectedAcpTranscriptHistoryEntries
    let liveEntries = selectedAcpTranscriptLiveEntries
    let transcriptSource = selectedAcpTranscriptSource
    acpTranscriptMergeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let output = await self.acpTimelineWorker.mergeTranscript(
        currentEntries: currentEntries,
        historyEntries: historyEntries,
        incoming: liveEntries
      )
      guard !Task.isCancelled, self.acpTranscriptMergeGeneration == generation else {
        return
      }
      if output.changed {
        self.replaceSelectedAcpTranscript(output.entries, transcriptSource: transcriptSource)
      } else if self.selectedAcpTranscriptSource != transcriptSource {
        self.replaceSelectedAcpTranscript(currentEntries, transcriptSource: transcriptSource)
      }
      self.acpTranscriptMergeTask = nil
    }
  }

  nonisolated(unsafe) private static let acpInspectRecordedAtFormatterFracSeconds:
    ISO8601DateFormatter =
      {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
      }()

  nonisolated(unsafe) private static let acpInspectRecordedAtFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  func applyAcpTimelineEntries(_ entries: [TimelineEntry]) {
    guard !entries.isEmpty else {
      return
    }
    acpTimelineMergeTask?.cancel()
    acpTimelineMergeGeneration &+= 1
    let generation = acpTimelineMergeGeneration
    let currentTimeline = timeline
    acpTimelineMergeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let output = await self.acpTimelineWorker.merge(
        current: currentTimeline,
        incoming: entries
      )
      guard !Task.isCancelled, self.acpTimelineMergeGeneration == generation else {
        return
      }
      if output.changed {
        self.replaceSelectedTimeline(output.entries)
      }
      self.acpTimelineMergeTask = nil
    }
  }

  func applyAcpTranscriptEntries(_ entries: [TimelineEntry]) {
    guard !entries.isEmpty else {
      return
    }
    selectedAcpTranscriptSource = .direct
    acpTranscriptLiveMergeTask?.cancel()
    acpTranscriptLiveMergeGeneration &+= 1
    let generation = acpTranscriptLiveMergeGeneration
    let currentLiveEntries = selectedAcpTranscriptLiveEntries
    let snapshots = selectedAcpAgents
    acpTranscriptLiveMergeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let output = await self.acpTimelineWorker.mergeAndReattribute(
        current: currentLiveEntries,
        incoming: entries,
        using: snapshots
      )
      guard !Task.isCancelled, self.acpTranscriptLiveMergeGeneration == generation else {
        return
      }
      if output.changed {
        self.selectedAcpTranscriptLiveEntries = output.entries
      }
      self.acpTranscriptLiveMergeTask = nil
    }
  }

  func replaceAcpTranscriptHistory(
    _ response: AcpTranscriptResponse,
    sessionID: String
  ) {
    guard sessionID == selectedSessionID else {
      return
    }
    selectedAcpTranscriptSource = .direct
    acpTranscriptHistoryTask?.cancel()
    acpTranscriptHistoryGeneration &+= 1
    let generation = acpTranscriptHistoryGeneration
    let currentHistoryEntries = selectedAcpTranscriptHistoryEntries
    let responseEntries = response.entries
    let liveEntries = selectedAcpTranscriptLiveEntries
    let snapshots = selectedAcpAgents
    acpTranscriptHistoryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let output = await self.acpTimelineWorker.prepareTranscriptHistory(
        currentHistoryEntries: currentHistoryEntries,
        responseEntries: responseEntries,
        liveEntries: liveEntries,
        using: snapshots
      )
      guard !Task.isCancelled, self.acpTranscriptHistoryGeneration == generation else {
        return
      }
      if output.historyChanged {
        self.selectedAcpTranscriptHistoryEntries = output.historyEntries
      }
      if output.liveChanged {
        self.selectedAcpTranscriptLiveEntries = output.liveEntries
      }
      self.acpTranscriptHistoryTask = nil
    }
  }

  func reattributeAcpTimelineEntries(using snapshots: [AcpAgentSnapshot]) {
    guard !timeline.isEmpty, !snapshots.isEmpty else {
      return
    }
    acpTimelineReattributeTask?.cancel()
    acpTimelineReattributeGeneration &+= 1
    let generation = acpTimelineReattributeGeneration
    let currentTimeline = timeline
    acpTimelineReattributeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let output = await self.acpTimelineWorker.reattribute(
        currentTimeline,
        using: snapshots
      )
      guard !Task.isCancelled, self.acpTimelineReattributeGeneration == generation else {
        return
      }
      if output.changed {
        self.replaceSelectedTimeline(output.entries)
      }
      self.acpTimelineReattributeTask = nil
    }
  }

  func reattributeAcpTranscriptEntries(using snapshots: [AcpAgentSnapshot]) {
    guard
      !selectedAcpTranscriptHistoryEntries.isEmpty
        || !selectedAcpTranscriptLiveEntries.isEmpty,
      !snapshots.isEmpty
    else {
      return
    }
    acpTranscriptReattributeTask?.cancel()
    acpTranscriptReattributeGeneration &+= 1
    let generation = acpTranscriptReattributeGeneration
    let historyEntries = selectedAcpTranscriptHistoryEntries
    let liveEntries = selectedAcpTranscriptLiveEntries
    acpTranscriptReattributeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      async let reattributedHistory = self.acpTimelineWorker.reattribute(
        historyEntries,
        using: snapshots
      )
      async let reattributedLive = self.acpTimelineWorker.reattribute(
        liveEntries,
        using: snapshots
      )
      let (updatedHistory, updatedLive) = await (reattributedHistory, reattributedLive)
      guard !Task.isCancelled, self.acpTranscriptReattributeGeneration == generation else {
        return
      }
      if updatedHistory.changed {
        self.selectedAcpTranscriptHistoryEntries = updatedHistory.entries
      }
      if updatedLive.changed {
        self.selectedAcpTranscriptLiveEntries = updatedLive.entries
      }
      self.acpTranscriptReattributeTask = nil
    }
  }

  private func reattributedAcpEntries(
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

  private func replaceSelectedTimeline(_ updatedTimeline: [TimelineEntry]) {
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

  private func replaceSelectedAcpTranscript(
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
        acpTimelineMergeTask,
        acpTranscriptMergeTask,
        acpTranscriptLiveMergeTask,
        acpTranscriptHistoryTask,
        acpTimelineReattributeTask,
        acpTranscriptReattributeTask,
        acpTranscriptPartitionTask,
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

  nonisolated private static func timelineEntrySortKey(for entry: TimelineEntry) -> TimelineEntrySortKey {
    TimelineEntrySortKey(
      entry: entry,
      toolCallSequence: entry.toolCallTimelineEntryMetadata()?.sequence
    )
  }
}

private struct AcpToolCallPhaseKey: Hashable {
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
