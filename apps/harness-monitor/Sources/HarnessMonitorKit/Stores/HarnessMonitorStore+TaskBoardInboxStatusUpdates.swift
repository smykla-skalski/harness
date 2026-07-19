import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func updateTaskBoardInboxStatuses(
    _ updates: [TaskBoardInboxStatusUpdate],
    actor: String = "harness-app"
  ) async -> Bool {
    await updateTaskBoardCardStatuses(
      taskBoardUpdates: [],
      inboxUpdates: updates,
      actor: actor
    )
  }

  func performTaskBoardInboxStatusUpdates(
    _ updates: [TaskBoardInboxStatusUpdate],
    actor: String,
    actionID: String,
    using client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    let optimisticRollback = applyOptimisticTaskBoardInboxStatuses(updates)

    let actor = controlPlaneActionActor(for: actor)
    var detailsBySessionID: [String: SessionDetail] = [:]
    var firstFailure: (sessionID: String, error: any Error)?
    for update in updates {
      do {
        let measuredDetail = try await Self.measureOperation {
          try await client.updateTask(
            sessionID: update.sessionID,
            taskID: update.taskID,
            request: TaskUpdateRequest(actor: actor, status: update.status, note: nil)
          )
        }
        recordRequestSuccess()
        detailsBySessionID[update.sessionID] = sessionDetailPreservingFresherSelectedSummary(
          sessionID: update.sessionID,
          detail: measuredDetail.value
        )
      } catch {
        if firstFailure == nil {
          firstFailure = (update.sessionID, error)
        }
      }
    }

    applyTaskBoardInboxStatusDetails(
      detailsBySessionID,
      orderedSessionIDs: orderedUniqueSessionIDs(updates.map(\.sessionID)),
      using: client
    )
    rollbackOptimisticTaskBoardInboxStatusesIfNeeded(
      optimisticRollback,
      reconciledSessionIDs: Set(detailsBySessionID.keys)
    )
    if let firstFailure {
      reportSelectedSessionActionFailure(
        "Move session tasks",
        sessionID: firstFailure.sessionID,
        error: firstFailure.error
      )
      presentSelectedSessionMutationFailure(firstFailure.error, actionID: actionID)
      return false
    }
    return true
  }

  @discardableResult
  private func applyOptimisticTaskBoardInboxStatuses(
    _ updates: [TaskBoardInboxStatusUpdate]
  ) -> TaskBoardInboxStatusRollback? {
    guard let selectedSessionID, let selectedSession else {
      return nil
    }
    let priorDetail = selectedSession
    let relevantUpdates = updates.filter { $0.sessionID == selectedSessionID }
    guard !relevantUpdates.isEmpty else {
      return nil
    }

    var changesByTaskID: [String: TaskBoardInboxStatusRollback.Change] = [:]
    for update in relevantUpdates {
      guard let task = priorDetail.tasks.first(where: { $0.taskId == update.taskID }),
        task.status != update.status
      else {
        continue
      }
      changesByTaskID[update.taskID] = .init(
        priorStatus: task.status,
        optimisticStatus: update.status
      )
    }
    guard !changesByTaskID.isEmpty else {
      return nil
    }
    let optimisticDetail = changesByTaskID.reduce(priorDetail) { detail, change in
      detail.withOptimisticTaskStatus(
        taskID: change.key,
        status: change.value.optimisticStatus
      )
    }
    applySelectedSessionSnapshot(
      sessionID: selectedSessionID,
      detail: optimisticDetail,
      timeline: timeline,
      timelineWindow: timelineWindow,
      clearBurstState: false,
      showingCachedData: isShowingCachedData,
      cancelPendingTimelineRefresh: false
    )
    return TaskBoardInboxStatusRollback(
      sessionID: selectedSessionID,
      changesByTaskID: changesByTaskID
    )
  }

  private func rollbackOptimisticTaskBoardInboxStatusesIfNeeded(
    _ rollback: TaskBoardInboxStatusRollback?,
    reconciledSessionIDs: Set<String>
  ) {
    guard let rollback,
      !reconciledSessionIDs.contains(rollback.sessionID),
      selectedSessionID == rollback.sessionID,
      let currentDetail = selectedSession,
      currentDetail.session.sessionId == rollback.sessionID
    else {
      return
    }

    let rolledBackDetail = rollback.changesByTaskID.reduce(currentDetail) { detail, change in
      guard
        detail.tasks.first(where: { $0.taskId == change.key })?.status
          == change.value.optimisticStatus
      else {
        return detail
      }
      return detail.withOptimisticTaskStatus(
        taskID: change.key,
        status: change.value.priorStatus
      )
    }
    guard rolledBackDetail != currentDetail else {
      return
    }
    applySelectedSessionSnapshot(
      sessionID: rollback.sessionID,
      detail: rolledBackDetail,
      timeline: timeline,
      timelineWindow: timelineWindow,
      clearBurstState: false,
      showingCachedData: isShowingCachedData,
      cancelPendingTimelineRefresh: false
    )
  }

  private func applyTaskBoardInboxStatusDetails(
    _ detailsBySessionID: [String: SessionDetail],
    orderedSessionIDs: [String],
    using client: any HarnessMonitorClientProtocol
  ) {
    withUISyncBatch {
      for sessionID in orderedSessionIDs {
        guard let detail = detailsBySessionID[sessionID] else {
          continue
        }
        applySessionSummaryUpdate(detail.session)
        guard selectedSessionID == sessionID else {
          continue
        }
        applySelectedSessionSnapshot(
          sessionID: sessionID,
          detail: detail,
          timeline: timeline,
          timelineWindow: timelineWindow,
          clearBurstState: false,
          showingCachedData: isShowingCachedData,
          cancelPendingTimelineRefresh: false
        )
      }
    }
    for sessionID in orderedSessionIDs where detailsBySessionID[sessionID] != nil {
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
    }
  }

  func deduplicatedTaskBoardInboxStatusUpdates(
    _ updates: [TaskBoardInboxStatusUpdate]
  ) -> [TaskBoardInboxStatusUpdate] {
    var seenIDs: Set<TaskBoardCardStatusUpdateID> = []
    return updates.filter { update in
      seenIDs.insert(
        TaskBoardCardStatusUpdateID(sessionID: update.sessionID, taskID: update.taskID)
      ).inserted
    }
  }
}

private struct TaskBoardCardStatusUpdateID: Hashable {
  let sessionID: String
  let taskID: String
}

private struct TaskBoardInboxStatusRollback {
  struct Change {
    let priorStatus: TaskStatus
    let optimisticStatus: TaskStatus
  }

  let sessionID: String
  let changesByTaskID: [String: Change]
}

extension SessionDetail {
  /// Locally-applied status used for optimistic UI feedback before the
  /// server confirms the move. Leaves every other task untouched; the
  /// authoritative reconciliation replaces this detail with the server
  /// response; rollback changes only this same field against current state.
  fileprivate func withOptimisticTaskStatus(
    taskID: String,
    status: TaskStatus
  ) -> SessionDetail {
    SessionDetail(
      session: session,
      agents: agents,
      tasks: tasks.map { $0.taskId == taskID ? $0.withOptimisticStatus(status) : $0 },
      signals: signals,
      observer: observer,
      agentActivity: agentActivity
    )
  }
}

extension WorkItem {
  func withOptimisticStatus(_ status: TaskStatus) -> WorkItem {
    WorkItem(
      taskId: taskId,
      title: title,
      context: context,
      severity: severity,
      status: status,
      assignedTo: assignedTo,
      queuePolicy: queuePolicy,
      queuedAt: queuedAt,
      createdAt: createdAt,
      updatedAt: updatedAt,
      createdBy: createdBy,
      notes: notes,
      suggestedFix: suggestedFix,
      source: source,
      blockedReason: blockedReason,
      completedAt: completedAt,
      checkpointSummary: checkpointSummary,
      awaitingReview: awaitingReview,
      reviewClaim: reviewClaim,
      consensus: consensus,
      reviewRound: reviewRound,
      arbitration: arbitration,
      suggestedPersona: suggestedPersona,
      reviewHistory: reviewHistory
    )
  }
}
