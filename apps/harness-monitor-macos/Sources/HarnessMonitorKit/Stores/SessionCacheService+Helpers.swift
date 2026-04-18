import Foundation
import SwiftData

extension SessionCacheService {
  func buildProjectMap(context: ModelContext) -> [String: CachedProject] {
    guard let projects = try? context.fetch(FetchDescriptor<CachedProject>()) else { return [:] }
    return Dictionary(uniqueKeysWithValues: projects.map { ($0.projectId, $0) })
  }

  func buildSessionMap(context: ModelContext) -> [String: CachedSession] {
    guard let sessions = try? context.fetch(FetchDescriptor<CachedSession>()) else { return [:] }
    return Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
  }

  func fetchCachedSession(sessionID: String, context: ModelContext) -> CachedSession? {
    var descriptor = FetchDescriptor<CachedSession>(
      predicate: #Predicate { $0.sessionId == sessionID }
    )
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  func upsertProject(_ project: ProjectSummary, context: ModelContext) {
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
  func upsertSession(_ summary: SessionSummary, context: ModelContext) -> Bool {
    if let existing = fetchCachedSession(sessionID: summary.sessionId, context: context) {
      existing.update(from: summary)
      return false
    }
    context.insert(summary.toCachedSession())
    return true
  }

  func persist(_ context: ModelContext, operation: String) async -> Bool {
    do {
      try Task.checkCancellation()
      try await beforeSave()
      try Task.checkCancellation()
      return try HarnessMonitorTelemetry.shared.withSQLiteOperation(
        operation: operation.replacingOccurrences(of: " ", with: "_"),
        access: "write",
        database: "monitor-cache",
        databasePath: databaseURL?.path
      ) {
        try saveChanges(context)
        return true
      }
    } catch is CancellationError {
      return false
    } catch {
      HarnessMonitorLogger.store.warning(
        "\(operation, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  func syncAgents(
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

  func syncTasks(
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

  func syncSignals(
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

  static let maxCachedTimelineEntries = 300

  func syncTimeline(
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

  func syncTimelineWindow(
    _ timelineWindow: TimelineWindowResponse?,
    timelineIsEmpty: Bool,
    on session: CachedSession
  ) {
    if let timelineWindow {
      session.timelineWindowData = try? Codecs.encoder.encode(timelineWindow.metadataOnly)
      return
    }
    // When the caller omits a window but the timeline it just wrote is empty,
    // the previously persisted window metadata is stale and would render as
    // "Showing 0-0 of N" until something else refreshes it. Drop it so reader
    // views recover without a manual reselect. We cannot trust
    // `session.timelineEntries` here because SwiftData keeps deleted but
    // unsaved relationship rows in the array until the next save.
    if timelineIsEmpty {
      session.timelineWindowData = nil
    }
  }

  func syncActivity(
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

  func syncObserver(
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

  func rolePriority(raw: String) -> Int {
    SessionRole(rawValue: raw)?.sortPriority ?? SessionRole.worker.sortPriority
  }

  func agentStatusPriority(raw: String) -> Int {
    AgentStatus(rawValue: raw)?.sortPriority ?? AgentStatus.removed.sortPriority
  }

  func taskSeverityPriority(raw: String) -> Int {
    TaskSeverity(rawValue: raw)?.sortPriority ?? TaskSeverity.low.sortPriority
  }
}
