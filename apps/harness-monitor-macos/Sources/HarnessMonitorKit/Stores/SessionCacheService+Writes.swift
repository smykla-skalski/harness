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
    let removedSessionIDs = Set(sessionMap.keys).subtracting(incomingSessionIDs)
    var insertedSessionCount = 0

    deleteTranscriptEntries(sessionIDs: removedSessionIDs, context: context)

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
    transcript: [TimelineEntry]? = nil,
    transcriptSource: HarnessMonitorSessionWindowTranscriptSource? = nil,
    timelineWindow: TimelineWindowResponse? = nil,
    markViewed: Bool = true,
    preservesTimeline: Bool = false
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
    if !preservesTimeline {
      syncTimeline(timeline, on: cached, context: context)
      syncTimelineWindow(timelineWindow, timelineIsEmpty: timeline.isEmpty, on: cached)
    }
    syncTranscript(
      transcript,
      transcriptSource: transcriptSource,
      sessionID: detail.session.sessionId,
      context: context
    )
    syncActivity(detail.agentActivity, on: cached, context: context)
    syncObserver(detail.observer, on: cached, context: context)

    let didPersist = await persist(context, operation: "cache session detail")
    return WriteResult(
      didPersist: didPersist,
      metadataUpdate: .advance(insertedSessionCount: insertedCount)
    )
  }

  func cacheSessionDetails(
    _ entries: [CachedSessionSnapshot],
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
    for entry in entries {
      let detail = entry.detail
      let timeline = entry.timeline
      let timelineWindow = entry.timelineWindow
      let transcript = entry.transcript
      let transcriptSource = entry.transcriptSource
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
      syncTranscript(
        transcript,
        transcriptSource: transcriptSource,
        sessionID: detail.session.sessionId,
        context: context
      )
      syncTimelineWindow(timelineWindow, timelineIsEmpty: timeline.isEmpty, on: cached)
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

  func replaceSessionWindowsOpenAtQuit(
    sessionIDs: Set<String>
  ) async -> WriteResult {
    await replaceSessionWindowsOpenAtQuit(
      snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot(sessionIDs: sessionIDs)
    )
  }

  func replaceSessionWindowsOpenAtQuit(
    snapshot: HarnessMonitorStore.SessionWindowQuitSnapshot
  ) async -> WriteResult {
    let context = makeContext()
    let descriptor = FetchDescriptor<CachedSessionWindowState>()
    let existing = (try? context.fetch(descriptor)) ?? []
    let now = Date.now
    let groupingByID = snapshot.groupingLookup()
    var seen: Set<String> = []
    for row in existing {
      if snapshot.sessionIDs.contains(row.sessionId) {
        if !row.wasOpenAtQuit {
          row.wasOpenAtQuit = true
        }
        row.updatedAt = now
        let placement = groupingByID[row.sessionId]
        row.tabGroupOrdinal = placement?.ordinal
        row.tabPosition = placement?.position
        row.wasForegroundTab = placement?.isForeground
        seen.insert(row.sessionId)
      } else {
        context.delete(row)
      }
    }
    for sessionID in snapshot.sessionIDs where !seen.contains(sessionID) {
      let placement = groupingByID[sessionID]
      context.insert(
        CachedSessionWindowState(
          sessionId: sessionID,
          wasOpenAtQuit: true,
          updatedAt: now,
          tabGroupOrdinal: placement?.ordinal,
          tabPosition: placement?.position,
          wasForegroundTab: placement?.isForeground
        )
      )
    }
    let didPersist = await persist(
      context,
      operation: "replace session windows open at quit"
    )
    return WriteResult(didPersist: didPersist, metadataUpdate: .refresh)
  }
}

extension HarnessMonitorStore.SessionWindowQuitSnapshot {
  fileprivate struct TabPlacement {
    let ordinal: Int
    let position: Int
    let isForeground: Bool
  }

  fileprivate func groupingLookup() -> [String: TabPlacement] {
    var lookup: [String: TabPlacement] = [:]
    for grouping in groupings {
      for (position, sessionID) in grouping.sessionIDs.enumerated() {
        lookup[sessionID] = TabPlacement(
          ordinal: grouping.ordinal,
          position: position,
          isForeground: grouping.foregroundSessionID == sessionID
        )
      }
    }
    return lookup
  }
}
