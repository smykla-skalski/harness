import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest
  ) async throws -> TimelineWindowResponse {
    try await timelineWindow(sessionID: sessionID, request: request) { _, _, _ in }
  }

  func timelineWindow(
    sessionID: String,
    request: TimelineWindowRequest,
    onBatch: @escaping TimelineWindowBatchHandler
  ) async throws -> TimelineWindowResponse {
    recordReadCall(.timelineWindow(sessionID))
    recordTimelineWindowRequest(sessionID: sessionID, request: request)
    recordTimelineScope(sessionID: sessionID, scope: request.scope ?? .full)
    try await sleepIfNeeded(
      configuredTimelineWindowDelay(for: sessionID) ?? configuredTimelineDelay(for: sessionID)
    )
    if let error = configuredTimelineWindowError(for: sessionID)
      ?? configuredTimelineError(for: sessionID)
    {
      throw error
    }
    if let response = configuredTimelineWindowResponse(for: sessionID) {
      await onBatch(response, 0, 1)
      return response
    }
    if let batches = configuredTimelineBatches(for: sessionID) {
      let batchCount = batches.count
      let allEntries = batches.flatMap(\.self)
      for (batchIndex, batch) in batches.enumerated() {
        await onBatch(
          timelineWindowResponse(entries: batch, request: request),
          batchIndex,
          batchCount
        )
        if batchIndex < batchCount - 1 {
          try await sleepIfNeeded(configuredTimelineBatchDelay(for: sessionID))
        }
      }
      return timelineWindowResponse(entries: allEntries, request: request)
    }
    let response = timelineWindowResponse(
      entries: configuredTimeline(for: sessionID) ?? PreviewFixtures.timeline,
      request: request
    )
    await onBatch(response, 0, 1)
    return response
  }

  func timeline(sessionID: String) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: .full)
  }

  func timeline(
    sessionID: String,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: .full, onBatch: onBatch)
  }

  func timeline(sessionID: String, scope: TimelineScope) async throws -> [TimelineEntry] {
    try await timeline(sessionID: sessionID, scope: scope) { _, _, _ in }
  }

  func timeline(
    sessionID: String,
    scope: TimelineScope,
    onBatch: @escaping TimelineBatchHandler
  ) async throws -> [TimelineEntry] {
    recordReadCall(.timeline(sessionID))
    recordTimelineScope(sessionID: sessionID, scope: scope)
    try await sleepIfNeeded(configuredTimelineDelay(for: sessionID))
    if let error = configuredTimelineError(for: sessionID) {
      throw error
    }
    if let batches = configuredTimelineBatches(for: sessionID) {
      let batchCount = batches.count
      for (batchIndex, batch) in batches.enumerated() {
        await onBatch(batch, batchIndex, batchCount)
        if batchIndex < batchCount - 1 {
          try await sleepIfNeeded(configuredTimelineBatchDelay(for: sessionID))
        }
      }
      return batches.flatMap(\.self)
    }
    return configuredTimeline(for: sessionID) ?? PreviewFixtures.timeline
  }

  private func timelineWindowResponse(
    entries: [TimelineEntry],
    request: TimelineWindowRequest
  ) -> TimelineWindowResponse {
    let totalCount = entries.count
    let revision = Int64(totalCount)
    let limit = max(1, request.limit ?? totalCount)

    if request.knownRevision == revision
      && request.before == nil
      && request.after == nil
    {
      let latestWindowEnd = min(limit, totalCount)
      return TimelineWindowResponse(
        revision: revision,
        totalCount: totalCount,
        windowStart: 0,
        windowEnd: latestWindowEnd,
        hasOlder: latestWindowEnd < totalCount,
        hasNewer: false,
        oldestCursor: latestWindowEnd > 0 ? entries[latestWindowEnd - 1].timelineCursor : nil,
        newestCursor: entries.first?.timelineCursor,
        entries: nil,
        unchanged: true
      )
    }

    let windowStart: Int
    let windowEntries: [TimelineEntry]
    if let before = request.before {
      let start =
        entries
        .firstIndex(where: { $0.recordedAt == before.recordedAt && $0.entryId == before.entryId })
        .map { $0 + 1 } ?? totalCount
      let end = min(start + limit, totalCount)
      windowStart = start
      windowEntries = Array(entries[start..<end])
    } else if let after = request.after {
      let end =
        entries
        .firstIndex(where: { $0.recordedAt == after.recordedAt && $0.entryId == after.entryId })
        ?? 0
      let start = max(0, end - limit)
      windowStart = start
      windowEntries = Array(entries[start..<end])
    } else {
      let end = min(limit, totalCount)
      windowStart = 0
      windowEntries = Array(entries.prefix(end))
    }

    let oldestCursor = windowEntries.last?.timelineCursor
    let newestCursor = windowEntries.first?.timelineCursor
    return TimelineWindowResponse(
      revision: revision,
      totalCount: totalCount,
      windowStart: windowStart,
      windowEnd: windowStart + windowEntries.count,
      hasOlder: windowStart + windowEntries.count < totalCount,
      hasNewer: windowStart > 0,
      oldestCursor: oldestCursor,
      newestCursor: newestCursor,
      entries: windowEntries,
      unchanged: false
    )
  }
}

extension TimelineEntry {
  fileprivate var timelineCursor: TimelineCursor {
    TimelineCursor(recordedAt: recordedAt, entryId: entryId)
  }
}
