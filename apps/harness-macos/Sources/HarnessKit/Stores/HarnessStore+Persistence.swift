import Foundation
import SwiftData

extension HarnessStore {
  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) {
    guard let modelContext, persistenceError == nil else { return }

    do {
      for project in projects {
        let projectId = project.projectId
        var descriptor = FetchDescriptor<CachedProject>(
          predicate: #Predicate { $0.projectId == projectId }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
          existing.update(from: project)
        } else {
          modelContext.insert(project.toCachedProject())
        }
      }

      for session in sessions {
        let sessionId = session.sessionId
        var descriptor = FetchDescriptor<CachedSession>(
          predicate: #Predicate { $0.sessionId == sessionId }
        )
        descriptor.fetchLimit = 1

        if let existing = try modelContext.fetch(descriptor).first {
          existing.update(from: session)
        } else {
          modelContext.insert(session.toCachedSession())
        }
      }

      try modelContext.save()
      refreshPersistedSessionMetadata()
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
      let sessionId = detail.session.sessionId
      var descriptor = FetchDescriptor<CachedSession>(
        predicate: #Predicate { $0.sessionId == sessionId }
      )
      descriptor.fetchLimit = 1

      let cached: CachedSession
      if let existing = try modelContext.fetch(descriptor).first {
        existing.update(from: detail.session)
        cached = existing
      } else {
        cached = detail.session.toCachedSession()
        modelContext.insert(cached)
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
      refreshPersistedSessionMetadata()
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Cached session detail could not be updated.",
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
}

// MARK: - Sync helpers

extension HarnessStore {
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
