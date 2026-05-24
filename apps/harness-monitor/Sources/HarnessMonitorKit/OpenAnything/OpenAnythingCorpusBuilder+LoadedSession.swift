extension OpenAnythingCorpusBuilder {
  static func appendLoadedSessionRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot?,
    to records: inout [OpenAnythingRecord]
  ) {
    guard let snapshot else { return }
    appendLoadedAgentRecords(snapshot, to: &records)
    guard !Task.isCancelled else { return }
    appendLoadedTaskRecords(snapshot, to: &records)
    guard !Task.isCancelled else { return }
    appendLoadedTimelineRecords(snapshot, to: &records)
  }

  private static func appendLoadedAgentRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot,
    to records: inout [OpenAnythingRecord]
  ) {
    for agent in snapshot.agents {
      guard !Task.isCancelled else { return }
      records.append(
        OpenAnythingRecord(
          id: "loadedSession.agent.\(snapshot.sessionID).\(agent.agentId)",
          domain: .loadedSession,
          target: .loadedSession(
            .agent(sessionID: snapshot.sessionID, agentID: agent.agentId)
          ),
          title: agent.name,
          subtitle: "Agent",
          trailing: agent.runtime,
          systemImage: "person.2",
          searchBodyParts: [
            agent.agentId,
            agent.persona?.name,
            agent.persona?.description,
            agent.role.rawValue,
          ]
        )
      )
    }
  }

  private static func appendLoadedTaskRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot,
    to records: inout [OpenAnythingRecord]
  ) {
    for task in snapshot.tasks {
      guard !Task.isCancelled else { return }
      records.append(
        OpenAnythingRecord(
          id: "loadedSession.task.\(snapshot.sessionID).\(task.taskId)",
          domain: .loadedSession,
          target: .loadedSession(.task(sessionID: snapshot.sessionID, taskID: task.taskId)),
          title: task.title,
          subtitle: "Task",
          trailing: displayLabel(task.status.rawValue),
          systemImage: "checklist",
          searchBodyParts: [
            task.taskId,
            task.context,
            task.suggestedFix,
            task.blockedReason,
          ]
        )
      )
    }
  }

  private static func appendLoadedTimelineRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot,
    to records: inout [OpenAnythingRecord]
  ) {
    forEachMostRecentTimelineEntry(snapshot.timeline, limit: 200) { entry in
      records.append(
        OpenAnythingRecord(
          id: "loadedSession.timeline.\(snapshot.sessionID).\(entry.entryId)",
          domain: .loadedSession,
          target: .loadedSession(
            .timeline(sessionID: snapshot.sessionID, entryID: entry.entryId)
          ),
          title: entry.summary.isEmpty ? entry.kind : entry.summary,
          subtitle: "Timeline",
          trailing: entry.kind,
          systemImage: "clock.arrow.circlepath",
          searchBodyParts: [entry.entryId, entry.agentId, entry.taskId]
        )
      )
    }
  }
}
