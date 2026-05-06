import Foundation

extension HarnessMonitorStore {
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
      .sorted(by: Self.timelineEntrySortOrder)
  }

  static func timelineEntrySortOrder(
    lhs: TimelineEntry,
    rhs: TimelineEntry
  ) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    if let lhsSequence = lhs.toolCallTimelineEntryMetadata()?.sequence,
      let rhsSequence = rhs.toolCallTimelineEntryMetadata()?.sequence,
      lhsSequence != rhsSequence
    {
      return lhsSequence > rhsSequence
    }
    return lhs.entryId < rhs.entryId
  }

  static func preferredTimelineEntry(
    _ lhs: TimelineEntry,
    over rhs: TimelineEntry
  ) -> TimelineEntry {
    timelineEntrySortOrder(lhs: lhs, rhs: rhs) ? lhs : rhs
  }

  static func parsedAcpInspectRecordedAt(_ recordedAt: String?) -> Date? {
    guard let recordedAt else {
      return nil
    }
    return acpInspectRecordedAtFormatterFracSeconds.date(from: recordedAt)
      ?? acpInspectRecordedAtFormatter.date(from: recordedAt)
  }

  func rebuildAcpTranscriptPartition() {
    var partition: [String: [TimelineEntry]] = [:]
    partition.reserveCapacity(selectedAcpTranscriptEntries.count)
    for entry in selectedAcpTranscriptEntries {
      guard let agentID = entry.agentId else { continue }
      partition[agentID, default: []].append(entry)
    }
    acpTranscriptByAgentID = partition
  }

  func rebuildSelectedAcpTranscriptEntries() {
    replaceSelectedAcpTranscriptIfNeeded(
      mergedTimelineEntries(
        selectedAcpTranscriptHistoryEntries,
        with: selectedAcpTranscriptLiveEntries
      )
    )
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
    let mergedTimeline = mergedTimelineEntries(timeline, with: entries)
    replaceSelectedTimelineIfNeeded(mergedTimeline)
  }

  func applyAcpTranscriptEntries(_ entries: [TimelineEntry]) {
    guard !entries.isEmpty else {
      return
    }
    replaceSelectedAcpTranscriptLiveIfNeeded(
      reattributedAcpEntries(
        mergedTimelineEntries(selectedAcpTranscriptLiveEntries, with: entries),
        using: selectedAcpAgents
      )
    )
  }

  func replaceAcpTranscriptHistory(
    _ response: AcpTranscriptResponse,
    sessionID: String
  ) {
    guard sessionID == selectedSessionID else {
      return
    }
    let historyEntries = reattributedAcpEntries(
      response.entries.filter(\.isAcpTranscriptResponseEntry),
      using: selectedAcpAgents
    )
    let historyEntryIDs = Set(historyEntries.map(\.entryId))
    replaceSelectedAcpTranscriptHistoryIfNeeded(historyEntries)
    replaceSelectedAcpTranscriptLiveIfNeeded(
      selectedAcpTranscriptLiveEntries.filter { !historyEntryIDs.contains($0.entryId) }
    )
  }

  func reattributeAcpTimelineEntries(using snapshots: [AcpAgentSnapshot]) {
    guard !timeline.isEmpty, !snapshots.isEmpty else {
      return
    }
    replaceSelectedTimelineIfNeeded(reattributedAcpEntries(timeline, using: snapshots))
  }

  func reattributeAcpTranscriptEntries(using snapshots: [AcpAgentSnapshot]) {
    guard
      !selectedAcpTranscriptHistoryEntries.isEmpty
        || !selectedAcpTranscriptLiveEntries.isEmpty,
      !snapshots.isEmpty
    else {
      return
    }
    replaceSelectedAcpTranscriptHistoryIfNeeded(
      reattributedAcpEntries(selectedAcpTranscriptHistoryEntries, using: snapshots)
    )
    replaceSelectedAcpTranscriptLiveIfNeeded(
      reattributedAcpEntries(selectedAcpTranscriptLiveEntries, using: snapshots)
    )
  }

  private func reattributedAcpEntries(
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

  private func replaceSelectedTimelineIfNeeded(_ updatedTimeline: [TimelineEntry]) {
    guard updatedTimeline != timeline else {
      return
    }
    timeline = updatedTimeline
    timelineWindow = normalizedTimelineWindow(timelineWindow, loadedTimeline: updatedTimeline)
    guard let selectedSession else {
      return
    }
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        selectedSession,
        timeline: updatedTimeline,
        timelineWindow: TimelineWindowResponse.fallbackMetadata(for: updatedTimeline)
      )
    }
  }

  private func replaceSelectedAcpTranscriptIfNeeded(_ updatedTimeline: [TimelineEntry]) {
    guard updatedTimeline != selectedAcpTranscriptEntries else {
      return
    }
    selectedAcpTranscriptEntries = updatedTimeline
  }

  private func replaceSelectedAcpTranscriptHistoryIfNeeded(_ updatedTimeline: [TimelineEntry]) {
    guard updatedTimeline != selectedAcpTranscriptHistoryEntries else {
      return
    }
    selectedAcpTranscriptHistoryEntries = updatedTimeline
  }

  private func replaceSelectedAcpTranscriptLiveIfNeeded(_ updatedTimeline: [TimelineEntry]) {
    guard updatedTimeline != selectedAcpTranscriptLiveEntries else {
      return
    }
    selectedAcpTranscriptLiveEntries = updatedTimeline
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
