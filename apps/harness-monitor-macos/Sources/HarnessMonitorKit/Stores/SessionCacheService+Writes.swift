import Foundation
import SwiftData

extension SessionCacheService {
  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) async -> WriteResult {
    let context = makeContext()
    let projectMap = buildProjectMap(context: context)
    let sessionMap = buildSessionMap(context: context)
    let incomingProjectIDs = Set(projects.map(\.projectId))
    let incomingSessionIDs = Set(sessions.map(\.sessionId))
    var insertedSessionCount = 0

    for (sessionID, existing) in sessionMap where !incomingSessionIDs.contains(sessionID) {
      context.delete(existing)
    }

    for (projectID, existing) in projectMap where !incomingProjectIDs.contains(projectID) {
      context.delete(existing)
    }

    for project in projects {
      if let existing = projectMap[project.projectId] {
        existing.update(from: project)
      } else {
        context.insert(project.toCachedProject())
      }
    }
    for session in sessions {
      if let existing = sessionMap[session.sessionId] {
        existing.update(from: session)
      } else {
        context.insert(session.toCachedSession())
        insertedSessionCount += 1
      }
    }
    let didPersist = await persist(context, operation: "cache session list")
    return WriteResult(
      didPersist: didPersist,
      metadataUpdate: .refresh
    )
  }

  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse? = nil,
    markViewed: Bool = true
  ) async -> WriteResult {
    let context = makeContext()
    let cached: CachedSession
    let insertedCount: Int
    if let existing = fetchCachedSession(sessionID: detail.session.sessionId, context: context) {
      existing.update(from: detail.session)
      cached = existing
      insertedCount = 0
    } else {
      cached = detail.session.toCachedSession()
      context.insert(cached)
      insertedCount = 1
    }

    if markViewed {
      cached.lastViewedAt = .now
    }

    syncAgents(detail.agents, on: cached, context: context)
    syncTasks(detail.tasks, on: cached, context: context)
    syncSignals(detail.signals, on: cached, context: context)
    syncTimeline(timeline, on: cached, context: context)
    syncTimelineWindow(timelineWindow, on: cached)
    syncActivity(detail.agentActivity, on: cached, context: context)
    syncObserver(detail.observer, on: cached, context: context)

    let didPersist = await persist(context, operation: "cache session detail")
    return WriteResult(
      didPersist: didPersist,
      metadataUpdate: .advance(insertedSessionCount: insertedCount)
    )
  }

  func cacheSessionDetails(
    _ entries: [(detail: SessionDetail, timeline: [TimelineEntry], timelineWindow: TimelineWindowResponse?)] ,
    markViewed: Bool = false
  ) async -> WriteResult {
    guard !entries.isEmpty else {
      return WriteResult(
        didPersist: true,
        metadataUpdate: .advance(insertedSessionCount: 0)
      )
    }

    let context = makeContext()
    let ids = entries.map(\.detail.session.sessionId)
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { ids.contains($0.sessionId) }
    )
    let existingByID: [String: CachedSession] = Dictionary(
      uniqueKeysWithValues: ((try? context.fetch(descriptor)) ?? []).map { ($0.sessionId, $0) }
    )

    var insertedCount = 0
    for (detail, timeline, timelineWindow) in entries {
      let cached: CachedSession
      if let existing = existingByID[detail.session.sessionId] {
        existing.update(from: detail.session)
        cached = existing
      } else {
        cached = detail.session.toCachedSession()
        context.insert(cached)
        insertedCount += 1
      }

      if markViewed {
        cached.lastViewedAt = .now
      }

      syncAgents(detail.agents, on: cached, context: context)
      syncTasks(detail.tasks, on: cached, context: context)
      syncSignals(detail.signals, on: cached, context: context)
      syncTimeline(timeline, on: cached, context: context)
      syncTimelineWindow(timelineWindow, on: cached)
      syncActivity(detail.agentActivity, on: cached, context: context)
      syncObserver(detail.observer, on: cached, context: context)
    }

    let didPersist = await persist(context, operation: "cache session details")
    return WriteResult(
      didPersist: didPersist,
      metadataUpdate: .advance(insertedSessionCount: insertedCount)
    )
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) async -> WriteResult {
    let context = makeContext()
    if let project {
      upsertProject(project, context: context)
    }

    let isInsert = upsertSession(summary, context: context)
    let didPersist = await persist(context, operation: "cache session summary")
    return WriteResult(
      didPersist: didPersist,
      metadataUpdate: .advance(insertedSessionCount: isInsert ? 1 : 0)
    )
  }
}
