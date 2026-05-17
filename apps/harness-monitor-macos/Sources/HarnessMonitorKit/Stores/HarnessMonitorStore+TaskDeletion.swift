import Foundation
extension HarnessMonitorStore {
  public func requestDeleteTaskConfirmation(
    sessionID: String,
    taskID: String,
    taskTitle: String
  ) {
    Task { @MainActor [weak self] in
      await self?.requestDeleteTaskConfirmationAsync(
        sessionID: sessionID,
        taskID: taskID,
        taskTitle: taskTitle
      )
    }
  }

  private func requestDeleteTaskConfirmationAsync(
    sessionID: String,
    taskID: String,
    taskTitle: String
  ) async {
    let actionName = "Delete task"
    guard prepareSessionAction(named: actionName, sessionID: sessionID) != nil else { return }
    pendingConfirmation = .deleteTask(
      sessionID: sessionID,
      taskID: taskID,
      taskTitle: taskTitle,
      actorID: controlPlaneActionActor(for: "harness-app"),
      noteCount: await taskUserNoteCount(taskID: taskID, sessionID: sessionID)
    )
  }

  public func requestDeleteTaskConfirmation(
    sessionID: String,
    taskIDs: [String],
    taskTitleProvider: (String) -> String
  ) {
    var titlesByID: [String: String] = [:]
    for taskID in taskIDs where titlesByID[taskID] == nil {
      titlesByID[taskID] = taskTitleProvider(taskID)
    }
    Task { @MainActor [weak self] in
      await self?.requestDeleteTaskConfirmationAsync(
        sessionID: sessionID,
        taskIDs: taskIDs,
        taskTitleProvider: { titlesByID[$0] ?? $0 }
      )
    }
  }

  private func requestDeleteTaskConfirmationAsync(
    sessionID: String,
    taskIDs: [String],
    taskTitleProvider: (String) -> String
  ) async {
    let normalized = orderedUniqueDeletionTaskIDs(taskIDs)
    guard !normalized.isEmpty else { return }
    let actionName = "Delete task"
    guard prepareSessionAction(named: actionName, sessionID: sessionID) != nil else { return }
    let actorID = controlPlaneActionActor(for: "harness-app")
    if normalized.count == 1 {
      let id = normalized[0]
      pendingConfirmation = .deleteTask(
        sessionID: sessionID,
        taskID: id,
        taskTitle: taskTitleProvider(id),
        actorID: actorID,
        noteCount: await taskUserNoteCount(taskID: id, sessionID: sessionID)
      )
    } else {
      pendingConfirmation = .deleteTasks(
        sessionID: sessionID,
        taskIDs: normalized,
        actorID: actorID
      )
    }
  }

  /// Stop-on-first-failure policy mirrors `removeAgents`: surface where the
  /// boundary fell rather than hammer through. Transient failure on item N
  /// strands items N+1…M; the toast names the unattempted suffix so the user
  /// can re-select and retry.
  @discardableResult
  func deleteTasks(
    sessionID: String,
    taskIDs: [String],
    actorID: String
  ) async -> Bool {
    guard !taskIDs.isEmpty else { return false }
    var succeeded = 0
    for (index, taskID) in taskIDs.enumerated() {
      let noteCount = await taskUserNoteCount(taskID: taskID, sessionID: sessionID)
      let didDelete = await deleteTask(
        sessionID: sessionID,
        taskID: taskID,
        actorID: actorID,
        expectedNoteCount: noteCount
      )
      guard didDelete else {
        let remaining = taskIDs.count - index - 1
        presentFailureFeedback(
          "Deleted \(succeeded) of \(taskIDs.count) tasks. "
            + "Stopped after a failure with \(remaining) not attempted."
        )
        return false
      }
      succeeded += 1
    }
    if taskIDs.count > 1 {
      presentSuccessFeedback("Deleted \(taskIDs.count) tasks")
    }
    return true
  }

  private func orderedUniqueDeletionTaskIDs(_ ids: [String]) -> [String] {
    var seen: Set<String> = []
    return ids.filter { seen.insert($0).inserted }
  }

  @discardableResult
  func deleteTask(
    sessionID: String,
    taskID: String,
    actorID: String,
    expectedNoteCount: Int
  ) async -> Bool {
    let actionName = "Delete task"
    guard let action = prepareSessionAction(named: actionName, sessionID: sessionID) else {
      return false
    }
    let actorID = controlPlaneActionActor(for: actorID)
    let didDelete = await mutateSelectedSession(
      actionName: actionName,
      actionID: ActionID.deleteTask(sessionID: sessionID, taskID: taskID).key,
      using: action.client,
      sessionID: sessionID,
      mutation: {
        try await action.client.deleteTask(
          sessionID: sessionID,
          taskID: taskID,
          request: TaskDeleteRequest(actor: actorID)
        )
      }
    )
    guard didDelete else {
      return false
    }
    dismissDeletedTaskSheetIfNeeded(sessionID: sessionID, taskID: taskID)
    let didDeleteNotes = await deleteTaskUserNotes(
      taskID: taskID,
      sessionID: sessionID,
      requiresPurge: expectedNoteCount > 0
    )
    if !didDeleteNotes, expectedNoteCount > 0 {
      let noteNoun = expectedNoteCount == 1 ? "note" : "notes"
      presentFailureFeedback(
        "Task deleted, but \(expectedNoteCount) local workspace \(noteNoun) could not be removed."
      )
    }
    return true
  }

  private func dismissDeletedTaskSheetIfNeeded(sessionID: String, taskID: String) {
    guard case .taskActions(let presentedSessionID, let presentedTaskID) = presentedSheet,
      presentedSessionID == sessionID,
      presentedTaskID == taskID
    else {
      return
    }
    dismissSheet()
  }

  private func taskUserNoteCount(taskID: String, sessionID: String) async -> Int {
    guard let userDataService, persistenceError == nil else {
      return 0
    }
    do {
      return try await userDataService.taskUserNoteCount(taskID: taskID, sessionID: sessionID)
    } catch {
      recordPersistenceFailure(
        action: "Task note count could not be loaded.",
        underlyingError: error
      )
      return 0
    }
  }

  private func deleteTaskUserNotes(
    taskID: String,
    sessionID: String,
    requiresPurge: Bool
  ) async -> Bool {
    guard let userDataService, persistenceError == nil else {
      return !requiresPurge
    }
    do {
      _ = try await userDataService.deleteTaskUserNotes(taskID: taskID, sessionID: sessionID)
      return true
    } catch {
      recordPersistenceFailure(
        action: "Task note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }
}
