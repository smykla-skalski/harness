import Foundation
import SwiftData

@ModelActor
public actor SessionCacheService {
  struct SessionMetadata: Sendable {
    let count: Int
    let lastCachedAt: Date?
  }

  struct CachedSessionSnapshot: Sendable {
    let detail: SessionDetail
    let timeline: [TimelineEntry]
  }

  public struct CacheCounts: Sendable {
    public let sessions: Int
    public let projects: Int
    public let agents: Int
    public let tasks: Int
    public let signals: Int
    public let timeline: Int
    public let observers: Int
    public let activities: Int

    public static let zero = CacheCounts(
      sessions: 0, projects: 0, agents: 0, tasks: 0,
      signals: 0, timeline: 0, observers: 0, activities: 0
    )
  }

  // MARK: - Reads

  func loadSessionDetail(
    sessionID: String
  ) -> CachedSessionSnapshot? {
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1

    guard let cached = try? modelContext.fetch(descriptor).first else {
      return nil
    }

    return CachedSessionSnapshot(
      detail: cached.toSessionDetail(),
      timeline: cached.timelineEntries.map { $0.toTimelineEntry() }
    )
  }

  func loadSessionList() -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
    let sessionDescriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )
    let projectDescriptor = FetchDescriptor<CachedProject>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )

    guard
      let sessions = try? modelContext.fetch(sessionDescriptor),
      let projects = try? modelContext.fetch(projectDescriptor),
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
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.lastViewedAt != nil },
      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    return ((try? modelContext.fetch(descriptor)) ?? []).map(\.sessionId)
  }

  func sessionMetadata() -> SessionMetadata {
    let count = (try? modelContext.fetchCount(FetchDescriptor<CachedSession>())) ?? 0
    var latestDescriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
    )
    latestDescriptor.fetchLimit = 1
    let latest = try? modelContext.fetch(latestDescriptor).first

    return SessionMetadata(count: count, lastCachedAt: latest?.lastCachedAt)
  }

  func hydrationQueue(for summaries: [SessionSummary]) -> [SessionSummary] {
    guard !summaries.isEmpty else { return [] }

    let summaryIds = summaries.map(\.sessionId)
    let descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { summaryIds.contains($0.sessionId) }
    )
    guard
      let cached = try? modelContext.fetch(descriptor)
    else {
      return summaries
    }

    let cachedBySessionID = Dictionary(
      uniqueKeysWithValues: cached.map { ($0.sessionId, $0) }
    )

    return summaries.filter { summary in
      guard let existing = cachedBySessionID[summary.sessionId] else {
        return true
      }
      return existing.updatedAt != summary.updatedAt || !hasDetailSnapshot(sessionId: existing.sessionId)
    }
  }

  // MARK: - Writes

  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) -> Int {
    let projectMap = buildProjectMap()
    let sessionMap = buildSessionMap()

    var insertedSessionCount = 0

    for project in projects {
      if let existing = projectMap[project.projectId] {
        existing.update(from: project)
      } else {
        modelContext.insert(project.toCachedProject())
      }
    }

    for session in sessions {
      if let existing = sessionMap[session.sessionId] {
        existing.update(from: session)
      } else {
        modelContext.insert(session.toCachedSession())
        insertedSessionCount += 1
      }
    }

    try? modelContext.save()
    return insertedSessionCount
  }

  @discardableResult
  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    markViewed: Bool = true
  ) -> Int {
    let cached: CachedSession
    let insertedCount: Int
    if let existing = fetchCachedSession(sessionID: detail.session.sessionId) {
      existing.update(from: detail.session)
      cached = existing
      insertedCount = 0
    } else {
      cached = detail.session.toCachedSession()
      modelContext.insert(cached)
      insertedCount = 1
    }

    if markViewed {
      cached.lastViewedAt = .now
    }

    syncAgents(detail.agents, on: cached)
    syncTasks(detail.tasks, on: cached)
    syncSignals(detail.signals, on: cached)
    syncTimeline(timeline, on: cached)
    syncActivity(detail.agentActivity, on: cached)
    syncObserver(detail.observer, on: cached)

    try? modelContext.save()
    return insertedCount
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) -> Bool {
    if let project {
      upsertProject(project)
    }

    let isInsert = upsertSession(summary)
    try? modelContext.save()
    return isInsert
  }

  // MARK: - Private helpers

  private func buildProjectMap() -> [String: CachedProject] {
    guard let projects = try? modelContext.fetch(FetchDescriptor<CachedProject>()) else {
      return [:]
    }
    return Dictionary(uniqueKeysWithValues: projects.map { ($0.projectId, $0) })
  }

  private func buildSessionMap() -> [String: CachedSession] {
    guard let sessions = try? modelContext.fetch(FetchDescriptor<CachedSession>()) else {
      return [:]
    }
    return Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
  }

  private func fetchCachedSession(sessionID: String) -> CachedSession? {
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1
    return try? modelContext.fetch(descriptor).first
  }

  private func hasDetailSnapshot(sessionId: String) -> Bool {
    var descriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { $0.sessionId == sessionId }
    )
    descriptor.fetchLimit = 1
    return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
  }

  private func upsertProject(_ project: ProjectSummary) {
    var descriptor = FetchDescriptor<CachedProject>(
      predicate: #Predicate { $0.projectId == project.projectId }
    )
    descriptor.fetchLimit = 1

    if let existing = try? modelContext.fetch(descriptor).first {
      existing.update(from: project)
    } else {
      modelContext.insert(project.toCachedProject())
    }
  }

  @discardableResult
  private func upsertSession(_ summary: SessionSummary) -> Bool {
    if let existing = fetchCachedSession(sessionID: summary.sessionId) {
      existing.update(from: summary)
      return false
    }

    modelContext.insert(summary.toCachedSession())
    return true
  }

  // MARK: - Sync helpers

  private func syncAgents(_ agents: [AgentRegistration], on session: CachedSession) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.agents.map { ($0.agentId, $0) }
    )
    let incomingIds = Set(agents.map(\.agentId))

    for agent in agents {
      if let existing = existingById[agent.agentId] {
        existing.update(from: agent)
      } else {
        session.agents.append(agent.toCachedAgent())
      }
    }

    for existing in session.agents where !incomingIds.contains(existing.agentId) {
      modelContext.delete(existing)
    }
  }

  private func syncTasks(_ tasks: [WorkItem], on session: CachedSession) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.tasks.map { ($0.taskId, $0) }
    )
    let incomingIds = Set(tasks.map(\.taskId))

    for task in tasks {
      if let existing = existingById[task.taskId] {
        existing.update(from: task)
      } else {
        session.tasks.append(task.toCachedWorkItem())
      }
    }

    for existing in session.tasks where !incomingIds.contains(existing.taskId) {
      modelContext.delete(existing)
    }
  }

  private func syncSignals(_ signals: [SessionSignalRecord], on session: CachedSession) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.signals.map { ($0.signalId, $0) }
    )
    let incomingIds = Set(signals.map(\.signal.signalId))

    for signal in signals {
      if let existing = existingById[signal.signal.signalId] {
        existing.update(from: signal)
      } else {
        session.signals.append(signal.toCachedSignalRecord())
      }
    }

    for existing in session.signals where !incomingIds.contains(existing.signalId) {
      modelContext.delete(existing)
    }
  }

  private static let maxCachedTimelineEntries = 300

  private func syncTimeline(_ entries: [TimelineEntry], on session: CachedSession) {
    let cappedEntries = Array(entries.suffix(Self.maxCachedTimelineEntries))

    let existingById = Dictionary(
      uniqueKeysWithValues: session.timelineEntries.map { ($0.entryId, $0) }
    )
    let incomingIds = Set(cappedEntries.map(\.entryId))

    for entry in cappedEntries {
      if let existing = existingById[entry.entryId] {
        existing.update(from: entry)
      } else {
        session.timelineEntries.append(entry.toCachedTimelineEntry())
      }
    }

    for existing in session.timelineEntries where !incomingIds.contains(existing.entryId) {
      modelContext.delete(existing)
    }
  }

  private func syncActivity(
    _ activities: [AgentToolActivitySummary],
    on session: CachedSession
  ) {
    for existing in session.agentActivity {
      modelContext.delete(existing)
    }
    session.agentActivity = []

    for activity in activities {
      session.agentActivity.append(activity.toCachedAgentActivity())
    }
  }

  private func syncObserver(_ observer: ObserverSummary?, on session: CachedSession) {
    if let existingObserver = session.observer {
      if let observer {
        existingObserver.update(from: observer)
      } else {
        modelContext.delete(existingObserver)
        session.observer = nil
      }
    } else if let observer {
      session.observer = observer.toCachedObserver()
    }
  }

  // MARK: - Database management

  func recordCounts() -> CacheCounts {
    CacheCounts(
      sessions: (try? modelContext.fetchCount(FetchDescriptor<CachedSession>())) ?? 0,
      projects: (try? modelContext.fetchCount(FetchDescriptor<CachedProject>())) ?? 0,
      agents: (try? modelContext.fetchCount(FetchDescriptor<CachedAgent>())) ?? 0,
      tasks: (try? modelContext.fetchCount(FetchDescriptor<CachedWorkItem>())) ?? 0,
      signals: (try? modelContext.fetchCount(FetchDescriptor<CachedSignalRecord>())) ?? 0,
      timeline: (try? modelContext.fetchCount(FetchDescriptor<CachedTimelineEntry>())) ?? 0,
      observers: (try? modelContext.fetchCount(FetchDescriptor<CachedObserver>())) ?? 0,
      activities: (try? modelContext.fetchCount(FetchDescriptor<CachedAgentActivity>())) ?? 0
    )
  }

  func deleteAllCacheData() -> Bool {
    do {
      let sessions = try modelContext.fetch(FetchDescriptor<CachedSession>())
      for session in sessions {
        modelContext.delete(session)
      }
      let projects = try modelContext.fetch(FetchDescriptor<CachedProject>())
      for project in projects {
        modelContext.delete(project)
      }
      try modelContext.save()
      return true
    } catch {
      return false
    }
  }
}
