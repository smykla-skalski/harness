import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func updateTaskBoardInboxStatuses(
    _ updates: [TaskBoardInboxStatusUpdate],
    actor: String = "harness-app"
  ) async -> Bool {
    let updates = deduplicatedTaskBoardInboxStatusUpdates(updates)
    guard
      let client,
      !updates.isEmpty,
      !isSessionReadOnly,
      !isSessionActionInFlight
    else {
      return false
    }

    let actionID = "task-board/inbox-status-batch"
    // Flip the in-flight flags before touching any state below, so the
    // guard above never observes this call's own optimistic write.
    isSessionActionInFlight = true
    inFlightActionID = actionID
    beginTaskBoardAction()
    defer {
      isSessionActionInFlight = false
      if inFlightActionID == actionID {
        inFlightActionID = nil
      }
      endTaskBoardAction()
    }

    // Only the currently-selected session has locally-held task state to
    // optimistically mutate; other sessions in the batch have nothing
    // rendered client-side to move early, same reach as the existing
    // success-path reconciliation below.
    let priorSelectedDetail = applyOptimisticTaskBoardInboxStatuses(updates)

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
      updates,
      priorSelectedDetail: priorSelectedDetail,
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
    presentSuccessFeedback(
      updates.count == 1 ? "Moved session task" : "Moved session tasks"
    )
    return true
  }

  /// Returns the pre-mutation detail for rollback, or `nil` when nothing
  /// was optimistically applied.
  @discardableResult
  private func applyOptimisticTaskBoardInboxStatuses(
    _ updates: [TaskBoardInboxStatusUpdate]
  ) -> SessionDetail? {
    guard let selectedSessionID, let selectedSession else {
      return nil
    }
    let priorDetail = selectedSession
    let relevantUpdates = updates.filter { $0.sessionID == selectedSessionID }
    guard !relevantUpdates.isEmpty else {
      return nil
    }
    let optimisticDetail = relevantUpdates.reduce(priorDetail) { detail, update in
      detail.withOptimisticTaskStatus(taskID: update.taskID, status: update.status)
    }
    guard optimisticDetail != priorDetail else {
      return nil
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
    return priorDetail
  }

  /// Restores the selected session's pre-mutation detail when none of its
  /// updates in this batch made it into `detailsBySessionID` - i.e. every
  /// update targeting it failed, so the authoritative reconciliation above
  /// never touched it and the optimistic write would otherwise persist.
  private func rollbackOptimisticTaskBoardInboxStatusesIfNeeded(
    _ updates: [TaskBoardInboxStatusUpdate],
    priorSelectedDetail: SessionDetail?,
    reconciledSessionIDs: Set<String>
  ) {
    guard let priorSelectedDetail, let selectedSessionID else {
      return
    }
    guard !reconciledSessionIDs.contains(selectedSessionID) else {
      return
    }
    guard updates.contains(where: { $0.sessionID == selectedSessionID }) else {
      return
    }
    applySelectedSessionSnapshot(
      sessionID: selectedSessionID,
      detail: priorSelectedDetail,
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

  private func deduplicatedTaskBoardInboxStatusUpdates(
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

extension SessionDetail {
  /// Locally-applied status used for optimistic UI feedback before the
  /// server confirms the move. Leaves every other task untouched; the
  /// authoritative reconciliation replaces this whole detail with the
  /// server response (or the prior detail, on rollback).
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
  fileprivate func withOptimisticStatus(_ status: TaskStatus) -> WorkItem {
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
