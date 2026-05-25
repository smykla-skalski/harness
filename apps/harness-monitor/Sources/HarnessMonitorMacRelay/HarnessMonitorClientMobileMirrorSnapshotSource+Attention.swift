import Foundation
import HarnessMonitorCore
import HarnessMonitorKit

extension HarnessMonitorClientMobileMirrorSnapshotSource {
  func staleSourceAttention(
    id: String,
    title: String,
    subtitle: String,
    now: Date
  ) -> MobileAttentionItem {
    MobileAttentionItem(
      id: id,
      stationID: stationID,
      kind: .stationHealth,
      severity: .warning,
      title: redacted(title),
      subtitle: redacted(subtitle),
      updatedAt: now,
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: revision
      ),
      commandPayload: ["scope": "mobileMirror"]
    )
  }

  func isTaskBoardMirrorAttention(_ item: MobileAttentionItem) -> Bool {
    item.kind == .taskBoard
      && (item.id.hasPrefix("task-board-plan-")
        || item.id.hasPrefix("task-board-needs-you-")
        || item.id.hasPrefix("task-board-blocked-"))
  }

  func reviewsUnavailableAttention(
    title: String,
    subtitle: String,
    severity: MobileAttentionSeverity,
    now: Date
  ) -> MobileAttentionItem {
    MobileAttentionItem(
      id: "reviews-unavailable-\(stationID)",
      stationID: stationID,
      kind: .stationHealth,
      severity: severity,
      title: redacted(title),
      subtitle: redacted(subtitle),
      updatedAt: now,
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        targetRevision: revision
      ),
      commandPayload: ["scope": "reviews"]
    )
  }

  func acpPermissionAttention(
    sessions: [SessionSummary],
    agentsBySessionID: [String: [ManagedAgentSnapshot]],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return agentsBySessionID.values.flatMap { agents in
      agents.flatMap { agent -> [MobileAttentionItem] in
        guard case .acp(let acp) = agent else {
          return []
        }
        return acp.pendingPermissionBatches.map { batch in
          let requestCount = batch.requests.count
          let session = sessionsByID[batch.sessionId]
          return MobileAttentionItem(
            id: "acp-\(batch.batchId)",
            stationID: stationID,
            kind: .acpDecision,
            severity: .critical,
            title: redacted("Permission requested by \(acp.displayName)"),
            subtitle: redacted(
              "\(requestCount) request\(requestCount == 1 ? "" : "s")"
                + " waiting in \(session?.displayTitle ?? batch.sessionId)."
            ),
            updatedAt: parseDate(batch.createdAt, fallback: now),
            commandKind: .acpPermissionDecision,
            target: MobileCommandTarget(
              stationID: stationID,
              sessionID: batch.sessionId,
              agentID: batch.acpId,
              targetRevision: revision
            ),
            commandPayload: ["batchID": batch.batchId, "decision": "approve_all"]
          )
        }
      }
    }
  }

  func reviewAttention(
    reviews: [ReviewItem],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    reviews.filter(needsReviewAttention).map { review in
      MobileAttentionItem(
        id: "review-\(review.pullRequestID)",
        stationID: stationID,
        kind: .pullRequest,
        severity: review.policyBlocked || review.checkStatus == .failure ? .critical : .warning,
        title: redacted("\(review.repository) #\(review.number) needs you"),
        subtitle: redacted(review.title),
        updatedAt: parseDate(review.updatedAt, fallback: now),
        commandKind: review.checkStatus == .failure ? .pullRequestRerunChecks : .pullRequestApprove,
        target: MobileCommandTarget(
          stationID: stationID,
          reviewID: review.pullRequestID,
          targetRevision: revision
        ),
        commandPayload: reviewPayload(review)
      )
    }
  }

  func taskBoardAttention(
    items: [TaskBoardItem],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    items.compactMap { item in
      switch item.status {
      case .planReview:
        return MobileAttentionItem(
          id: "task-board-plan-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: .critical,
          title: "Plan approval needed",
          subtitle: redacted(taskBoardSubtitle(item)),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .taskBoardPlanApproval,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: ["approvedBy": "mobile"]
        )
      case .needsYou:
        return MobileAttentionItem(
          id: "task-board-needs-you-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: taskBoardSeverity(item),
          title: "Task needs you",
          subtitle: redacted(taskBoardSubtitle(item)),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .taskBoardDispatch,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: [
            "itemID": item.id,
            "status": "todo",
            "dryRun": "false",
          ]
        )
      case .blocked:
        return MobileAttentionItem(
          id: "task-board-blocked-\(item.id)",
          stationID: stationID,
          kind: .taskBoard,
          severity: taskBoardSeverity(item),
          title: "Task is blocked",
          subtitle: redacted(taskBoardSubtitle(item)),
          updatedAt: parseDate(item.updatedAt, fallback: now),
          commandKind: .refresh,
          target: MobileCommandTarget(
            stationID: stationID,
            taskID: item.id,
            targetRevision: revision
          ),
          commandPayload: ["scope": "taskBoard"]
        )
      default:
        return nil
      }
    }
  }

  func sessionTaskAttention(
    sessions: [SessionSummary],
    detailsBySessionID: [String: SessionDetail],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return detailsBySessionID.values.flatMap { detail in
      let session = sessionsByID[detail.session.sessionId] ?? detail.session
      return detail.tasks.compactMap { task in
        sessionTaskAttentionItem(
          session: session,
          task: task,
          revision: revision,
          now: now
        )
      }
    }
  }

  func sessionTaskAttentionItem(
    session: SessionSummary,
    task: WorkItem,
    revision: Int64,
    now: Date
  ) -> MobileAttentionItem? {
    let title: String
    let severity: MobileAttentionSeverity
    switch task.status {
    case .awaitingReview:
      title = "Task awaiting review"
      severity = sessionTaskSeverity(task)
    case .blocked:
      title = "Task is blocked"
      severity = sessionTaskSeverity(task)
    case .open, .inProgress, .inReview, .done:
      guard task.requiresArbitrationBanner else {
        return nil
      }
      title = "Task arbitration needed"
      severity = .critical
    }

    return MobileAttentionItem(
      id: "session-task-\(session.sessionId)-\(task.taskId)",
      stationID: stationID,
      kind: .taskBoard,
      severity: severity,
      title: title,
      subtitle: redacted(sessionTaskSubtitle(session: session, task: task)),
      updatedAt: parseDate(task.updatedAt, fallback: now),
      commandKind: .refresh,
      target: MobileCommandTarget(
        stationID: stationID,
        sessionID: session.sessionId,
        taskID: task.taskId,
        targetRevision: revision
      ),
      commandPayload: [
        "scope": "sessionTasks",
        "sessionID": session.sessionId,
        "taskID": task.taskId,
        "status": task.status.rawValue,
      ]
    )
  }

  func blockedAgentAttention(
    sessions: [SessionSummary],
    agentsBySessionID: [String: [ManagedAgentSnapshot]],
    revision: Int64,
    now: Date
  ) -> [MobileAttentionItem] {
    let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })
    return agentsBySessionID.values.flatMap { agents in
      agents.compactMap { agent -> MobileAttentionItem? in
        guard isBlocked(agent), agent.acp?.pendingPermissionBatches.isEmpty != false else {
          return nil
        }
        let session = sessionsByID[agent.sessionId]
        return MobileAttentionItem(
          id: "blocked-\(agent.managedAgentID)",
          stationID: stationID,
          kind: .blockedAgent,
          severity: .warning,
          title: redacted("\(agent.displayTitle) is waiting"),
          subtitle: redacted(session?.displayTitle ?? agent.sessionId),
          updatedAt: parseDate(agent.updatedAt, fallback: now),
          commandKind: .agentPrompt,
          target: MobileCommandTarget(
            stationID: stationID,
            sessionID: agent.sessionId,
            agentID: agent.managedAgentID,
            targetRevision: revision
          ),
          commandPayload: ["prompt": "Please summarize what you need from me."]
        )
      }
    }
  }
}
