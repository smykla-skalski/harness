import Foundation

extension HarnessMonitorStore {
  static func acpInspectSampledAt(from recordedAt: String?) -> Date {
    parsedAcpInspectRecordedAt(recordedAt) ?? Date()
  }

  func acpToolCallTimelineMetadata(
    for payload: AcpEventBatchPayload
  ) -> AcpToolCallTimelineMetadata {
    let snapshot = selectedAcpAgents.first { $0.acpId == payload.acpId }
    let fallbackAgentID = payload.events.lazy.map(\.agent).first { !$0.isEmpty } ?? payload.acpId
    let descriptorID = snapshot?.agentId ?? fallbackAgentID
    let descriptor = acpAgentDescriptorsByID[descriptorID]
    return AcpToolCallTimelineMetadata(
      acpAgentId: payload.acpId,
      agentId: snapshot?.agentId ?? descriptor?.id ?? fallbackAgentID,
      displayName: snapshot?.displayName ?? descriptor?.displayName ?? snapshot?.agentId
        ?? fallbackAgentID,
      capabilityTags: descriptor?.capabilities ?? []
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
    guard mergedTimeline != timeline else {
      return
    }
    timeline = mergedTimeline
    timelineWindow = normalizedTimelineWindow(timelineWindow, loadedTimeline: mergedTimeline)
    guard let selectedSession else {
      return
    }
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        selectedSession,
        timeline: mergedTimeline,
        timelineWindow: TimelineWindowResponse.fallbackMetadata(for: mergedTimeline)
      )
    }
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
