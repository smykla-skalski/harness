import Foundation
import SwiftData

public actor SessionCacheService {
  private let modelContainer: ModelContainer

  public init(modelContainer: ModelContainer) {
    self.modelContainer = modelContainer
  }

  struct SessionMetadata: Sendable {
    let count: Int
    let lastCachedAt: Date?
  }

  struct CachedSessionSnapshot: Sendable {
    let detail: SessionDetail
    let timeline: [TimelineEntry]
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
      timeline: cached.timelineEntries.map { $0.toTimelineEntry() }
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

    var snapshotState: [String: (updatedAt: String?, hasTimeline: Bool)] = [:]
    for session in cached {
      snapshotState[session.sessionId] = (
        updatedAt: session.updatedAt,
        hasTimeline: hasDetailSnapshot(sessionId: session.sessionId, context: context)
      )
    }

    return summaries.filter { summary in
      guard let state = snapshotState[summary.sessionId] else {
        return true
      }
      return state.updatedAt != summary.updatedAt || !state.hasTimeline
    }
  }

  // MARK: - Writes

  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) -> Int {
    let context = makeContext()
    let projectMap = buildProjectMap(context: context)
    let sessionMap = buildSessionMap(context: context)
    var insertedSessionCount = 0
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
    try? context.save()
    return insertedSessionCount
  }

  @discardableResult
  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    markViewed: Bool = true
  ) -> Int {
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
    syncActivity(detail.agentActivity, on: cached, context: context)
    syncObserver(detail.observer, on: cached, context: context)

    try? context.save()
    return insertedCount
  }

  @discardableResult
  func cacheSessionDetails(
    _ entries: [(detail: SessionDetail, timeline: [TimelineEntry])],
    markViewed: Bool = false
  ) -> Int {
    guard !entries.isEmpty else {
      return 0
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
    for (detail, timeline) in entries {
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
      syncActivity(detail.agentActivity, on: cached, context: context)
      syncObserver(detail.observer, on: cached, context: context)
    }

    try? context.save()
    return insertedCount
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) -> Bool {
    let context = makeContext()
    if let project {
      upsertProject(project, context: context)
    }

    let isInsert = upsertSession(summary, context: context)
    try? context.save()
    return isInsert
  }

  // MARK: - Private helpers

  private func buildProjectMap(context: ModelContext) -> [String: CachedProject] {
    guard let projects = try? context.fetch(FetchDescriptor<CachedProject>()) else { return [:] }
    return Dictionary(uniqueKeysWithValues: projects.map { ($0.projectId, $0) })
  }

  private func buildSessionMap(context: ModelContext) -> [String: CachedSession] {
    guard let sessions = try? context.fetch(FetchDescriptor<CachedSession>()) else { return [:] }
    return Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
  }

  private func fetchCachedSession(sessionID: String, context: ModelContext) -> CachedSession? {
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  private func hasDetailSnapshot(sessionId: String, context: ModelContext) -> Bool {
    var descriptor = FetchDescriptor<CachedTimelineEntry>(
      predicate: #Predicate { $0.sessionId == sessionId }
    )
    descriptor.fetchLimit = 1
    return ((try? context.fetchCount(descriptor)) ?? 0) > 0
  }

  private func upsertProject(_ project: ProjectSummary, context: ModelContext) {
    var descriptor = FetchDescriptor<CachedProject>(
      predicate: #Predicate { $0.projectId == project.projectId }
    )
    descriptor.fetchLimit = 1
    if let existing = try? context.fetch(descriptor).first {
      existing.update(from: project)
    } else {
      context.insert(project.toCachedProject())
    }
  }

  @discardableResult
  private func upsertSession(_ summary: SessionSummary, context: ModelContext) -> Bool {
    if let existing = fetchCachedSession(sessionID: summary.sessionId, context: context) {
      existing.update(from: summary)
      return false
    }
    context.insert(summary.toCachedSession())
    return true
  }

  // MARK: - Sync helpers

  private func syncAgents(
    _ agents: [AgentRegistration],
    on session: CachedSession,
    context: ModelContext
  ) {
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
      context.delete(existing)
    }

    session.agents.sort { left, right in
      let leftRole = rolePriority(raw: left.roleRaw)
      let rightRole = rolePriority(raw: right.roleRaw)
      if leftRole != rightRole {
        return leftRole < rightRole
      }

      let leftStatus = agentStatusPriority(raw: left.statusRaw)
      let rightStatus = agentStatusPriority(raw: right.statusRaw)
      if leftStatus != rightStatus {
        return leftStatus < rightStatus
      }

      if left.joinedAt != right.joinedAt {
        return left.joinedAt < right.joinedAt
      }
      return left.agentId < right.agentId
    }
  }

  private func syncTasks(
    _ tasks: [WorkItem],
    on session: CachedSession,
    context: ModelContext
  ) {
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
      context.delete(existing)
    }

    session.tasks.sort { left, right in
      let leftSeverity = taskSeverityPriority(raw: left.severityRaw)
      let rightSeverity = taskSeverityPriority(raw: right.severityRaw)
      if leftSeverity != rightSeverity {
        return leftSeverity > rightSeverity
      }
      if left.updatedAt != right.updatedAt {
        return left.updatedAt > right.updatedAt
      }
      if left.createdAt != right.createdAt {
        return left.createdAt > right.createdAt
      }
      return left.taskId < right.taskId
    }
  }

  private func syncSignals(
    _ signals: [SessionSignalRecord],
    on session: CachedSession,
    context: ModelContext
  ) {
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
      context.delete(existing)
    }
  }

  private static let maxCachedTimelineEntries = 300

  private func syncTimeline(
    _ entries: [TimelineEntry],
    on session: CachedSession,
    context: ModelContext
  ) {
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
      context.delete(existing)
    }
  }

  private func syncActivity(
    _ activities: [AgentToolActivitySummary],
    on session: CachedSession,
    context: ModelContext
  ) {
    for existing in session.agentActivity {
      context.delete(existing)
    }
    session.agentActivity = []

    for activity in activities {
      session.agentActivity.append(activity.toCachedAgentActivity())
    }
  }

  private func syncObserver(
    _ observer: ObserverSummary?,
    on session: CachedSession,
    context: ModelContext
  ) {
    if let existingObserver = session.observer {
      if let observer {
        existingObserver.update(from: observer)
      } else {
        context.delete(existingObserver)
        session.observer = nil
      }
    } else if let observer {
      session.observer = observer.toCachedObserver()
    }
  }

  private func rolePriority(raw: String) -> Int {
    SessionRole(rawValue: raw)?.sortPriority ?? SessionRole.worker.sortPriority
  }

  private func agentStatusPriority(raw: String) -> Int {
    AgentStatus(rawValue: raw)?.sortPriority ?? AgentStatus.removed.sortPriority
  }

  private func taskSeverityPriority(raw: String) -> Int {
    TaskSeverity(rawValue: raw)?.sortPriority ?? TaskSeverity.low.sortPriority
  }

}
