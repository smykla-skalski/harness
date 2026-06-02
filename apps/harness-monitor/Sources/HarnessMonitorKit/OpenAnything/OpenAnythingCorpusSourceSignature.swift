/// Cheap content hash for the source data that feeds the Open Anything corpus.
///
/// The SwiftUI host uses this as its `.task(id:)` trigger so body evaluation
/// does not allocate `[OpenAnythingRecord]` or sort timeline rows. It must
/// include every source field that can change a generated record.
public enum OpenAnythingCorpusSourceSignature {
  public static func compute(_ input: OpenAnythingCorpusInput) -> Int {
    var hasher = Hasher()
    hasher.combine(OpenAnythingCorpusSignature.salt)
    combine(input.settingsSections, into: &hasher, with: combineSettingsSection)
    combine(input.sessions, into: &hasher, with: combineSession)
    combine(input.taskBoardItems, into: &hasher, with: combineTaskBoardItem)
    combine(input.decisions, into: &hasher, with: combineDecision)
    combine(input.reviews, into: &hasher, with: combineReview)
    combineLoadedSession(input.loadedSession, into: &hasher)
    return hasher.finalize()
  }

  private static func combine<Element>(
    _ values: [Element],
    into hasher: inout Hasher,
    with combineElement: (Element, inout Hasher) -> Void
  ) {
    hasher.combine(values.count)
    for value in values {
      combineElement(value, &hasher)
    }
  }

  private static func combineSettingsSection(
    _ section: OpenAnythingSettingsSectionProjection,
    into hasher: inout Hasher
  ) {
    hasher.combine(section.rawValue)
    hasher.combine(section.title)
    hasher.combine(section.systemImage)
  }

  private static func combineSession(_ session: SessionSummary, into hasher: inout Hasher) {
    hasher.combine(session.sessionId)
    hasher.combine(session.displayTitle)
    hasher.combine(session.status.rawValue)
    hasher.combine(session.projectName)
    hasher.combine(session.contextRoot)
    hasher.combine(session.branchRef)
    hasher.combine(session.context)
    hasher.combine(session.worktreePath)
    hasher.combine(session.checkoutRoot)
  }

  private static func combineTaskBoardItem(
    _ item: TaskBoardItem,
    into hasher: inout Hasher
  ) {
    hasher.combine(item.id)
    hasher.combine(item.sessionId)
    hasher.combine(item.workItemId)
    hasher.combine(item.title)
    hasher.combine(item.status.rawValue)
    hasher.combine(item.priority.rawValue)
    hasher.combine(item.body)
    combine(item.tags, into: &hasher) { tag, hasher in
      hasher.combine(tag)
    }
  }

  private static func combineDecision(
    _ decision: DecisionPresentationSnapshot,
    into hasher: inout Hasher
  ) {
    hasher.combine(decision.id)
    hasher.combine(decision.sessionID)
    hasher.combine(decision.summary)
    hasher.combine(decision.ruleID)
    hasher.combine(decision.severityRaw)
    hasher.combine(decision.agentID)
    hasher.combine(decision.taskID)
  }

  private static func combineReview(_ review: ReviewItem, into hasher: inout Hasher) {
    hasher.combine(review.pullRequestID)
    hasher.combine(review.repository)
    hasher.combine(review.number)
    hasher.combine(review.title)
    hasher.combine(review.authorLogin)
    hasher.combine(review.checkStatus.rawValue)
    combine(review.labels, into: &hasher) { label, hasher in
      hasher.combine(label)
    }
  }

  private static func combineLoadedSession(
    _ snapshot: OpenAnythingLoadedSessionSnapshot?,
    into hasher: inout Hasher
  ) {
    guard let snapshot else {
      hasher.combine(false)
      return
    }
    hasher.combine(true)
    hasher.combine(snapshot.sessionID)
    combine(snapshot.agents, into: &hasher, with: combineLoadedAgent)
    combine(snapshot.tasks, into: &hasher, with: combineLoadedTask)
    hasher.combine(min(snapshot.timeline.count, 200))
    let timeline = snapshot.timeline
    OpenAnythingCorpusBuilder.forEachMostRecentTimelineEntry(timeline, limit: 200) { entry in
      combineLoadedTimelineEntry(entry, into: &hasher)
    }
  }

  private static func combineLoadedAgent(
    _ agent: AgentRegistration,
    into hasher: inout Hasher
  ) {
    hasher.combine(agent.agentId)
    hasher.combine(agent.name)
    hasher.combine(agent.runtime)
    hasher.combine(agent.role.rawValue)
    hasher.combine(agent.persona?.name)
    hasher.combine(agent.persona?.description)
  }

  private static func combineLoadedTask(_ task: WorkItem, into hasher: inout Hasher) {
    hasher.combine(task.taskId)
    hasher.combine(task.title)
    hasher.combine(task.status.rawValue)
    hasher.combine(task.context)
    hasher.combine(task.suggestedFix)
    hasher.combine(task.blockedReason)
  }

  private static func combineLoadedTimelineEntry(
    _ entry: TimelineEntry,
    into hasher: inout Hasher
  ) {
    hasher.combine(entry.entryId)
    hasher.combine(entry.recordedAt)
    hasher.combine(entry.kind)
    hasher.combine(entry.summary)
    hasher.combine(entry.agentId)
    hasher.combine(entry.taskId)
  }
}
