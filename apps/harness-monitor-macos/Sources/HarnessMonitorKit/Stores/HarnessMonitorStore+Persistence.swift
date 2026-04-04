import Foundation
import SwiftData

extension HarnessMonitorStore {
  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      var insertedSessionCount = 0

      for project in projects {
        try upsertCachedProject(project, in: modelContext)
      }

      for session in sessions {
        insertedSessionCount += try upsertCachedSession(session, in: modelContext) ? 1 : 0
      }

      try modelContext.save()
      updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedSessionCount)
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Cached session summaries could not be updated.",
        underlyingError: error
      )
    }
  }

  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry],
    markViewed: Bool = true
  ) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      let cached: CachedSession
      let insertedSessionCount: Int
      if let existing = try cachedSession(
        sessionID: detail.session.sessionId,
        in: modelContext
      ) {
        existing.update(from: detail.session)
        cached = existing
        insertedSessionCount = 0
      } else {
        cached = detail.session.toCachedSession()
        modelContext.insert(cached)
        insertedSessionCount = 1
      }

      if markViewed {
        cached.lastViewedAt = .now
      }

      syncAgents(detail.agents, on: cached, in: modelContext)
      syncTasks(detail.tasks, on: cached, in: modelContext)
      syncSignals(detail.signals, on: cached, in: modelContext)
      syncTimeline(timeline, on: cached, in: modelContext)
      syncActivity(detail.agentActivity, on: cached, in: modelContext)
      syncObserver(detail.observer, on: cached, in: modelContext)

      try modelContext.save()
      updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedSessionCount)
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Cached session detail could not be updated.",
        underlyingError: error
      )
    }
  }

  func cacheSessionSummary(
    _ summary: SessionSummary,
    project: ProjectSummary?
  ) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      if let project {
        try upsertCachedProject(project, in: modelContext)
      }

      let insertedSessionCount = try upsertCachedSession(summary, in: modelContext) ? 1 : 0
      try modelContext.save()
      updatePersistedSessionMetadataAfterSave(insertedSessionCount: insertedSessionCount)
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Cached session summary could not be updated.",
        underlyingError: error
      )
    }
  }

  func loadCachedSessionList() -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
    guard let modelContext, persistenceError == nil else { return nil }

    do {
      let sessionDescriptor = FetchDescriptor<CachedSession>(
        sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
      )
      let projectDescriptor = FetchDescriptor<CachedProject>(
        sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
      )

      let sessions = try modelContext.fetch(sessionDescriptor)
      let projects = try modelContext.fetch(projectDescriptor)
      guard !sessions.isEmpty else {
        return nil
      }

      return (
        sessions: sessions.map { $0.toSessionSummary() },
        projects: projects.map { $0.toProjectSummary() }
      )
    } catch {
      recordPersistenceFailure(
        action: "Cached session summaries could not be loaded.",
        underlyingError: error
      )
      return nil
    }
  }

  func loadCachedSessionDetail(
    sessionID: String
  ) -> (detail: SessionDetail, timeline: [TimelineEntry])? {
    guard let modelContext, persistenceError == nil else { return nil }

    do {
      var descriptor = FetchDescriptor<CachedSession>(
        predicate: #Predicate { $0.sessionId == sessionID }
      )
      descriptor.fetchLimit = 1

      guard let cached = try modelContext.fetch(descriptor).first else {
        return nil
      }

      return (
        detail: cached.toSessionDetail(),
        timeline: cached.timelineEntries.map { $0.toTimelineEntry() }
      )
    } catch {
      recordPersistenceFailure(
        action: "Cached session detail could not be loaded.",
        underlyingError: error
      )
      return nil
    }
  }

  func refreshPersistedSessionMetadata() {
    guard let modelContext, persistenceError == nil else {
      persistedSessionCount = 0
      lastPersistedSnapshotAt = nil
      return
    }

    do {
      let count = try modelContext.fetchCount(FetchDescriptor<CachedSession>())
      var latestDescriptor = FetchDescriptor<CachedSession>(
        sortBy: [SortDescriptor(\.lastCachedAt, order: .reverse)]
      )
      latestDescriptor.fetchLimit = 1
      let latest = try modelContext.fetch(latestDescriptor).first

      persistedSessionCount = count
      lastPersistedSnapshotAt = latest?.lastCachedAt
    } catch {
      recordPersistenceFailure(
        action: "Persisted session metadata could not be loaded.",
        underlyingError: error
      )
      persistedSessionCount = 0
      lastPersistedSnapshotAt = nil
    }
  }

  func persistedSnapshotNeedsHydration(for summary: SessionSummary) -> Bool {
    guard let modelContext, persistenceError == nil else {
      return false
    }

    do {
      let sessionID = summary.sessionId
      var descriptor = FetchDescriptor<CachedSession>(
        predicate: #Predicate { $0.sessionId == sessionID }
      )
      descriptor.fetchLimit = 1

      guard let cached = try modelContext.fetch(descriptor).first else {
        return true
      }

      return cached.updatedAt != summary.updatedAt || !hasPersistedDetailSnapshot(cached)
    } catch {
      recordPersistenceFailure(
        action: "Persisted session hydration state could not be evaluated.",
        underlyingError: error
      )
      return true
    }
  }

  private func hasPersistedDetailSnapshot(_ session: CachedSession) -> Bool {
    session.observer != nil
      || !session.agents.isEmpty
      || !session.tasks.isEmpty
      || !session.signals.isEmpty
      || !session.timelineEntries.isEmpty
      || !session.agentActivity.isEmpty
  }

  private func updatePersistedSessionMetadataAfterSave(insertedSessionCount: Int) {
    persistedSessionCount += insertedSessionCount
    lastPersistedSnapshotAt = .now
  }

  private func upsertCachedProject(
    _ project: ProjectSummary,
    in context: ModelContext
  ) throws {
    if let existing = try cachedProject(projectID: project.projectId, in: context) {
      existing.update(from: project)
    } else {
      context.insert(project.toCachedProject())
    }
  }

  @discardableResult
  private func upsertCachedSession(
    _ summary: SessionSummary,
    in context: ModelContext
  ) throws -> Bool {
    if let existing = try cachedSession(sessionID: summary.sessionId, in: context) {
      existing.update(from: summary)
      return false
    }

    context.insert(summary.toCachedSession())
    return true
  }

  private func cachedProject(
    projectID: String,
    in context: ModelContext
  ) throws -> CachedProject? {
    var descriptor = FetchDescriptor<CachedProject>(
      predicate: #Predicate { $0.projectId == projectID }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  private func cachedSession(
    sessionID: String,
    in context: ModelContext
  ) throws -> CachedSession? {
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }
}

// MARK: - Sync helpers

extension HarnessMonitorStore {
  private func syncAgents(
    _ agents: [AgentRegistration],
    on session: CachedSession,
    in context: ModelContext
  ) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.agents.map { ($0.agentId, $0) }
    )
    let incomingIds = Set(agents.map(\.agentId))

    for agent in agents {
      if let existing = existingById[agent.agentId] {
        existing.update(from: agent)
      } else {
        let cached = agent.toCachedAgent()
        session.agents.append(cached)
      }
    }

    for existing in session.agents where !incomingIds.contains(existing.agentId) {
      context.delete(existing)
    }
  }

  private func syncTasks(
    _ tasks: [WorkItem],
    on session: CachedSession,
    in context: ModelContext
  ) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.tasks.map { ($0.taskId, $0) }
    )
    let incomingIds = Set(tasks.map(\.taskId))

    for task in tasks {
      if let existing = existingById[task.taskId] {
        existing.update(from: task)
      } else {
        let cached = task.toCachedWorkItem()
        session.tasks.append(cached)
      }
    }

    for existing in session.tasks where !incomingIds.contains(existing.taskId) {
      context.delete(existing)
    }
  }

  private func syncSignals(
    _ signals: [SessionSignalRecord],
    on session: CachedSession,
    in context: ModelContext
  ) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.signals.map { ($0.signalId, $0) }
    )
    let incomingIds = Set(signals.map(\.signal.signalId))

    for signal in signals {
      if let existing = existingById[signal.signal.signalId] {
        existing.update(from: signal)
      } else {
        let cached = signal.toCachedSignalRecord()
        session.signals.append(cached)
      }
    }

    for existing in session.signals where !incomingIds.contains(existing.signalId) {
      context.delete(existing)
    }
  }

  private func syncTimeline(
    _ entries: [TimelineEntry],
    on session: CachedSession,
    in context: ModelContext
  ) {
    let existingById = Dictionary(
      uniqueKeysWithValues: session.timelineEntries.map { ($0.entryId, $0) }
    )
    let incomingIds = Set(entries.map(\.entryId))

    for entry in entries {
      if let existing = existingById[entry.entryId] {
        existing.update(from: entry)
      } else {
        let cached = entry.toCachedTimelineEntry()
        session.timelineEntries.append(cached)
      }
    }

    for existing in session.timelineEntries where !incomingIds.contains(existing.entryId) {
      context.delete(existing)
    }
  }

  private func syncActivity(
    _ activities: [AgentToolActivitySummary],
    on session: CachedSession,
    in context: ModelContext
  ) {
    for existing in session.agentActivity {
      context.delete(existing)
    }
    session.agentActivity = []

    for activity in activities {
      let cached = activity.toCachedAgentActivity()
      session.agentActivity.append(cached)
    }
  }

  private func syncObserver(
    _ observer: ObserverSummary?,
    on session: CachedSession,
    in context: ModelContext
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
}
