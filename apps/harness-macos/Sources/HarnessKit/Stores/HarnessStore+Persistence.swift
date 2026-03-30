import Foundation
import SwiftData

extension HarnessStore {
  private static let maxCachedSessions = 50

  func cacheSessionList(
    _ sessions: [SessionSummary],
    projects: [ProjectSummary]
  ) {
    guard let modelContext else { return }

    for project in projects {
      let projectId = project.projectId
      var descriptor = FetchDescriptor<CachedProject>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      if let existing = try? modelContext.fetch(descriptor).first {
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

      if let existing = try? modelContext.fetch(descriptor).first {
        existing.update(from: session)
      } else {
        modelContext.insert(session.toCachedSession())
      }
    }

    try? modelContext.save()
  }

  func cacheSessionDetail(
    _ detail: SessionDetail,
    timeline: [TimelineEntry]
  ) {
    guard let modelContext else { return }

    let sessionId = detail.session.sessionId
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionId }
    )
    descriptor.fetchLimit = 1

    let cached: CachedSession
    if let existing = try? modelContext.fetch(descriptor).first {
      existing.update(from: detail.session)
      cached = existing
    } else {
      cached = detail.session.toCachedSession()
      modelContext.insert(cached)
    }

    cached.lastViewedAt = .now

    syncAgents(detail.agents, on: cached, in: modelContext)
    syncTasks(detail.tasks, on: cached, in: modelContext)
    syncSignals(detail.signals, on: cached, in: modelContext)
    syncTimeline(timeline, on: cached, in: modelContext)
    syncActivity(detail.agentActivity, on: cached, in: modelContext)
    syncObserver(detail.observer, on: cached, in: modelContext)

    try? modelContext.save()
    evictStaleSessions(in: modelContext)
  }

  func loadCachedSessionList() -> (
    sessions: [SessionSummary],
    projects: [ProjectSummary]
  )? {
    guard let modelContext else { return nil }

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

  func loadCachedSessionDetail(
    sessionID: String
  ) -> (detail: SessionDetail, timeline: [TimelineEntry])? {
    guard let modelContext else { return nil }

    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1

    guard let cached = try? modelContext.fetch(descriptor).first,
      cached.lastViewedAt != nil
    else {
      return nil
    }

    return (
      detail: cached.toSessionDetail(),
      timeline: cached.timelineEntries.map { $0.toTimelineEntry() }
    )
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

  private func evictStaleSessions(in context: ModelContext) {
    var descriptor = FetchDescriptor<CachedSession>(
      sortBy: [SortDescriptor(\.lastViewedAt, order: .reverse)]
    )
    descriptor.fetchOffset = Self.maxCachedSessions

    guard let stale = try? context.fetch(descriptor), !stale.isEmpty else {
      return
    }

    let evictedProjectIds = Set(stale.map(\.projectId))
    for session in stale {
      context.delete(session)
    }

    try? context.save()
    evictOrphanedProjects(candidateIds: evictedProjectIds, in: context)
  }

  private func evictOrphanedProjects(
    candidateIds: Set<String>,
    in context: ModelContext
  ) {
    for projectId in candidateIds {
      var descriptor = FetchDescriptor<CachedSession>(
        predicate: #Predicate { $0.projectId == projectId }
      )
      descriptor.fetchLimit = 1

      let hasRemaining = (try? context.fetchCount(descriptor)) ?? 0
      if hasRemaining == 0 {
        let projectDescriptor = FetchDescriptor<CachedProject>(
          predicate: #Predicate { $0.projectId == projectId }
        )
        if let orphaned = try? context.fetch(projectDescriptor) {
          for project in orphaned {
            context.delete(project)
          }
        }
      }
    }

    try? context.save()
  }
}
