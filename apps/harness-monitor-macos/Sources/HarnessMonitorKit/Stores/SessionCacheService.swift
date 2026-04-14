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
  let beforeSave: () async throws -> Void
  let saveChanges: (ModelContext) throws -> Void

  public init(
    modelContainer: ModelContainer,
    beforeSave: @escaping @Sendable () async throws -> Void = {},
    saveChanges: @escaping @Sendable (ModelContext) throws -> Void = { context in
      try context.save()
    }
  ) {
    self.modelContainer = modelContainer
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
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1

    guard let cached = try? context.fetch(descriptor).first else {
      return nil
    }

    return CachedSessionSnapshot(
      detail: cached.toSessionDetail(),
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
  }

  func loadSessionList() -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
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
      return nil
    }

    return (
      sessions: sessions.map { $0.toSessionSummary() },
      projects: projects.map { $0.toProjectSummary() }
    )
  }

  func recentlyViewedSessionIDs(limit: Int) -> [String] {
    let context = makeContext()
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.lastViewedAt != nil },
      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    return ((try? context.fetch(descriptor)) ?? []).map(\.sessionId)
  }

  func sessionMetadata() -> SessionMetadata {
    let context = makeContext()
    let count = (try? context.fetchCount(FetchDescriptor<CachedSession>())) ?? 0
    var latestDescriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )
    latestDescriptor.fetchLimit = 1
    let latest = try? context.fetch(latestDescriptor).first

    return SessionMetadata(count: count, lastCachedAt: latest?.lastCachedAt)
  }

  func hydrationQueue(for summaries: [SessionSummary]) -> [SessionSummary] {
    guard !summaries.isEmpty else { return [] }

    let context = makeContext()
    let summaryIds = summaries.map(\.sessionId)
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { summaryIds.contains($0.sessionId) }
    )
    guard let cached = try? context.fetch(descriptor) else { return summaries }
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

    return summaries.filter { summary in
      guard let hasTimeline = snapshotState[summary.sessionId] else {
        return true
      }
      // Background hydration is a startup fallback, not the authoritative live
      // refresh path. Once a session already has a cached timeline, keep that
      // snapshot and let the selected-session live load fetch exact detail on
      // demand instead of rehydrating every recently viewed session in the
      // background whenever only the summary timestamp changes.
      return !hasTimeline
    }
  }

}
