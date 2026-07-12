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
    isSessionActionInFlight = true
    inFlightActionID = actionID
    defer {
      isSessionActionInFlight = false
      if inFlightActionID == actionID {
        inFlightActionID = nil
      }
    }

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
