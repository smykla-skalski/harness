import Foundation
import SwiftData

extension SessionCacheService {
  // MARK: - Reads

  func loadSessionDetail(
    sessionID: String
  ) -> CachedSessionSnapshot? {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1

    guard let cached = try? context.fetch(descriptor).first else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "load_session_detail", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return nil
    }

    let reviewMetadata = fetchReviewMetadata(
      context: context,
      sessionID: sessionID
    )
    let transcript = resolvedTranscriptSnapshot(sessionID: sessionID, context: context)
    let result = CachedSessionSnapshot(
      detail: cached.toSessionDetail(reviewMetadataByTaskId: reviewMetadata),
      timeline: sortedTimelineEntries(cached.timelineEntries.map { $0.toTimelineEntry() }),
      timelineWindow: cached.decodedTimelineWindow(),
      transcript: transcript.entries,
      transcriptSource: transcript.source
    )
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_detail", hit: true, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return result
  }

  func loadSessionDetails(
    sessionIDs: [String]
  ) -> [String: CachedSessionSnapshot] {
    let startedAt = ContinuousClock.now
    guard !sessionIDs.isEmpty else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "load_session_details", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return [:]
    }

    let context = makeContext()
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { sessionIDs.contains($0.sessionId) }
    )
    guard let cached = try? context.fetch(descriptor), !cached.isEmpty else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "load_session_details", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return [:]
    }

    let snapshots = Dictionary(
      uniqueKeysWithValues: cached.map { session in
        let reviewMetadata = fetchReviewMetadata(
          context: context,
          sessionID: session.sessionId
        )
        let transcript = resolvedTranscriptSnapshot(
          sessionID: session.sessionId,
          context: context
        )
        return (
          session.sessionId,
          CachedSessionSnapshot(
            detail: session.toSessionDetail(reviewMetadataByTaskId: reviewMetadata),
            timeline: sortedTimelineEntries(session.timelineEntries.map { $0.toTimelineEntry() }),
            timelineWindow: session.decodedTimelineWindow(),
            transcript: transcript.entries,
            transcriptSource: transcript.source
          )
        )
      }
    )
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_details", hit: true, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return snapshots
  }

  func loadSessionList() -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    let sessionDescriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )
    let projectDescriptor = FetchDescriptor<CachedProject>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )

    guard
      let sessions = try? context.fetch(sessionDescriptor),
      let projects = try? context.fetch(projectDescriptor),
      !sessions.isEmpty
    else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "load_session_list", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return nil
    }

    let result = (
      sessions: sessions.map { $0.toSessionSummary() },
      projects: projects.map { $0.toProjectSummary() }
    )
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_list", hit: true, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return result
  }

  func recentlyViewedSessionIDs(limit: Int? = nil) -> [String] {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.lastViewedAt != nil },
      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
    )
    if let limit {
      let normalizedLimit = max(limit, 0)
      guard normalizedLimit > 0 else {
        #if HARNESS_FEATURE_OTEL
          let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
          HarnessMonitorTelemetry.shared.recordCacheRead(
            operation: "recently_viewed_session_ids", hit: false, durationMs: durationMs
          )
        #else
          _ = startedAt
        #endif
        return []
      }
      descriptor.fetchLimit = normalizedLimit
    }
    let ids = ((try? context.fetch(descriptor)) ?? []).map(\.sessionId)
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "recently_viewed_session_ids", hit: !ids.isEmpty, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return ids
  }

  func sessionTabGroupsAtQuit() -> [HarnessMonitorStore.SessionTabGroupSnapshot] {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSessionWindowState>(
      predicate: #Predicate { row in
        row.wasOpenAtQuit && row.tabGroupOrdinal != nil
      }
    )
    descriptor.sortBy = [
      SortDescriptor(\.tabGroupOrdinal),
      SortDescriptor(\.tabPosition),
    ]
    let rows = (try? context.fetch(descriptor)) ?? []
    var groupedByOrdinal: [Int: [CachedSessionWindowState]] = [:]
    for row in rows {
      guard let ordinal = row.tabGroupOrdinal else { continue }
      groupedByOrdinal[ordinal, default: []].append(row)
    }
    return groupedByOrdinal.keys.sorted().map { ordinal in
      let members = groupedByOrdinal[ordinal] ?? []
      let sortedMembers = members.sorted {
        ($0.tabPosition ?? Int.max) < ($1.tabPosition ?? Int.max)
      }
      return HarnessMonitorStore.SessionTabGroupSnapshot(
        ordinal: ordinal,
        sessionIDs: sortedMembers.map(\.sessionId),
        foregroundSessionID: sortedMembers.first(where: { $0.wasForegroundTab == true })?
          .sessionId
      )
    }
  }

  func sessionWindowIDsOpenAtQuit(limit: Int? = nil) -> [String] {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSessionWindowState>(
      predicate: #Predicate { $0.wasOpenAtQuit },
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
    )
    if let limit {
      let normalizedLimit = max(limit, 0)
      guard normalizedLimit > 0 else {
        #if HARNESS_FEATURE_OTEL
          let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
          HarnessMonitorTelemetry.shared.recordCacheRead(
            operation: "session_window_ids_open_at_quit", hit: false, durationMs: durationMs
          )
        #else
          _ = startedAt
        #endif
        return []
      }
      descriptor.fetchLimit = normalizedLimit
    }
    let ids = ((try? context.fetch(descriptor)) ?? []).map(\.sessionId)
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "session_window_ids_open_at_quit", hit: !ids.isEmpty, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return ids
  }

  func sessionMetadata() -> SessionMetadata {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    let count = (try? context.fetchCount(FetchDescriptor<CachedSession>())) ?? 0
    var latestDescriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )
    latestDescriptor.fetchLimit = 1
    let latest = try? context.fetch(latestDescriptor).first
    let result = SessionMetadata(count: count, lastCachedAt: latest?.lastCachedAt)
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "session_metadata", hit: count > 0, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return result
  }

  func hydrationQueue(for summaries: [SessionSummary]) -> [SessionSummary] {
    let startedAt = ContinuousClock.now
    guard !summaries.isEmpty else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "hydration_queue", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return []
    }

    let context = makeContext()
    let summaryIds = summaries.map(\.sessionId)
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { summaryIds.contains($0.sessionId) }
    )
    guard let cached = try? context.fetch(descriptor) else {
      #if HARNESS_FEATURE_OTEL
        let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
        HarnessMonitorTelemetry.shared.recordCacheRead(
          operation: "hydration_queue", hit: false, durationMs: durationMs
        )
      #else
        _ = startedAt
      #endif
      return summaries
    }
    let timelineDescriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { summaryIds.contains($0.sessionId) }
    )
    let timelineSessionIDs = Set(
      ((try? context.fetch(timelineDescriptor)) ?? []).map(\.sessionId)
    )

    var snapshotState: [String: Bool] = [:]
    for session in cached {
      snapshotState[session.sessionId] = timelineSessionIDs.contains(session.sessionId)
    }

    let result = summaries.filter { summary in
      guard let hasTimeline = snapshotState[summary.sessionId] else {
        return true
      }
      return !hasTimeline
    }
    #if HARNESS_FEATURE_OTEL
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "hydration_queue", hit: !cached.isEmpty, durationMs: durationMs
      )
    #else
      _ = startedAt
    #endif
    return result
  }

  /// Fetch the `(taskId -> review metadata)` map for a session from the
  /// V8 side-table. Missing rows are simply absent from the returned
  /// dictionary, which callers treat as an empty review block.
  func fetchReviewMetadata(
    context: ModelContext,
    sessionID: String
  ) -> [String: CachedReviewMetadata] {
    let descriptor = FetchDescriptor<CachedTaskReviewMetadata>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    guard let rows = try? context.fetch(descriptor), !rows.isEmpty else {
      return [:]
    }
    return Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in
        let payload = decodedReviewMetadata(from: row.reviewBlob)
        return payload.isEmpty ? nil : (row.taskId, payload)
      }
    )
  }
}
