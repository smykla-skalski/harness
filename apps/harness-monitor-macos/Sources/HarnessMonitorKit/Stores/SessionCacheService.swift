import Foundation
import SwiftData

public actor SessionCacheService {
  enum MetadataUpdate: Sendable {
    case refresh
    case advance(insertedSessionCount: Int)
  }

  struct WriteResult: Sendable {
    let didPersist: Bool
    let metadataUpdate: MetadataUpdate
  }

  let modelContainer: ModelContainer
  let databaseURL: URL?
  let beforeSave: () async throws -> Void
  let saveChanges: (ModelContext) throws -> Void

  public init(
    modelContainer: ModelContainer,
    databaseURL: URL? = nil,
    beforeSave: @escaping @Sendable () async throws -> Void = {},
    saveChanges: @escaping @Sendable (ModelContext) throws -> Void = { context in
      try context.save()
    }
  ) {
    self.modelContainer = modelContainer
    self.databaseURL = databaseURL
    self.beforeSave = beforeSave
    self.saveChanges = saveChanges
  }

  struct SessionMetadata: Sendable {
    let count: Int
    let lastCachedAt: Date?
  }

  struct CachedSessionSnapshot: Sendable {
    let detail: SessionDetail
    let timeline: [TimelineEntry]
    let timelineWindow: TimelineWindowResponse?
  }

  func makeContext() -> ModelContext {
    let context = ModelContext(modelContainer)
    context.autosaveEnabled = false
    return context
  }

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
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_detail", hit: false, durationMs: durationMs
      )
      return nil
    }

    let reviewMetadata = fetchReviewMetadata(
      context: context,
      sessionID: sessionID
    )
    let result = CachedSessionSnapshot(
      detail: cached.toSessionDetail(reviewMetadataByTaskId: reviewMetadata),
      timeline: cached.timelineEntries
        .map { $0.toTimelineEntry() }
        .sorted { left, right in
          if left.recordedAt != right.recordedAt {
            return left.recordedAt > right.recordedAt
          }
          return left.entryId > right.entryId
        },
      timelineWindow: cached.decodedTimelineWindow()
    )
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_detail", hit: true, durationMs: durationMs
    )
    return result
  }

  func loadSessionDetails(
    sessionIDs: [String]
  ) -> [String: CachedSessionSnapshot] {
    let startedAt = ContinuousClock.now
    guard !sessionIDs.isEmpty else {
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_details", hit: false, durationMs: durationMs
      )
      return [:]
    }

    let context = makeContext()
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { sessionIDs.contains($0.sessionId) }
    )
    guard let cached = try? context.fetch(descriptor), !cached.isEmpty else {
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_details", hit: false, durationMs: durationMs
      )
      return [:]
    }

    let snapshots = Dictionary(
      uniqueKeysWithValues: cached.map { session in
        let reviewMetadata = fetchReviewMetadata(
          context: context,
          sessionID: session.sessionId
        )
        return (
          session.sessionId,
          CachedSessionSnapshot(
            detail: session.toSessionDetail(reviewMetadataByTaskId: reviewMetadata),
            timeline: session.timelineEntries
              .map { $0.toTimelineEntry() }
              .sorted { left, right in
                if left.recordedAt != right.recordedAt {
                  return left.recordedAt > right.recordedAt
                }
                return left.entryId > right.entryId
              },
            timelineWindow: session.decodedTimelineWindow()
          )
        )
      }
    )
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_details", hit: true, durationMs: durationMs
    )
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
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "load_session_list", hit: false, durationMs: durationMs
      )
      return nil
    }

    let result = (
      sessions: sessions.map { $0.toSessionSummary() },
      projects: projects.map { $0.toProjectSummary() }
    )
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "load_session_list", hit: true, durationMs: durationMs
    )
    return result
  }

  func recentlyViewedSessionIDs(limit: Int) -> [String] {
    let startedAt = ContinuousClock.now
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.lastViewedAt != nil },
      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    let ids = ((try? context.fetch(descriptor)) ?? []).map(\.sessionId)
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "recently_viewed_session_ids", hit: !ids.isEmpty, durationMs: durationMs
    )
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
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "session_metadata", hit: count > 0, durationMs: durationMs
    )
    return result
  }

  func hydrationQueue(for summaries: [SessionSummary]) -> [SessionSummary] {
    let startedAt = ContinuousClock.now
    guard !summaries.isEmpty else {
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "hydration_queue", hit: false, durationMs: durationMs
      )
      return []
    }

    let context = makeContext()
    let summaryIds = summaries.map(\.sessionId)
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { summaryIds.contains($0.sessionId) }
    )
    guard let cached = try? context.fetch(descriptor) else {
      let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
      HarnessMonitorTelemetry.shared.recordCacheRead(
        operation: "hydration_queue", hit: false, durationMs: durationMs
      )
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
    let durationMs = harnessMonitorDurationMilliseconds(startedAt.duration(to: .now))
    HarnessMonitorTelemetry.shared.recordCacheRead(
      operation: "hydration_queue", hit: !cached.isEmpty, durationMs: durationMs
    )
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
