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

  public func requestTaskBoardDeletionConfirmation(
    targets: [TaskBoardDeletionTarget]
  ) {
    let targets = orderedUniqueTaskBoardDeletionTargets(targets)
    guard !targets.isEmpty else { return }
    let actionName = targets.count == 1 ? "Delete task" : "Delete tasks"
    guard taskBoardDeletionActionIsAvailable(actionName: actionName) else { return }
    pendingConfirmation = .deleteTaskBoardTargets(targets: targets)
  }

  public var canDeleteTaskBoardTargets: Bool {
    !isBusy && !isTaskBoardBusy && !isSessionReadOnly && client != nil
  }

  @discardableResult
  func deleteTaskBoardTargets(_ targets: [TaskBoardDeletionTarget]) async -> Bool {
    let targets = orderedUniqueTaskBoardDeletionTargets(targets)
    guard !targets.isEmpty else { return false }
    let actionName = targets.count == 1 ? "Delete task" : "Delete tasks"
    guard taskBoardDeletionActionIsAvailable(actionName: actionName), let client else {
      return false
    }

    let taskBoardItemIDs = targets.compactMap { target -> String? in
      guard case .taskBoardItem(let id, _) = target else { return nil }
      return id
    }
    let inboxGroups = taskBoardInboxDeletionGroups(targets)
    beginTaskBoardAction()
    let sessionActionToken =
      inboxGroups.isEmpty
      ? nil
      : beginSessionAction(actionID: "task-board/delete-targets")
    defer {
      if let sessionActionToken {
        endSessionAction(sessionActionToken)
      }
      endTaskBoardAction()
    }

    if !taskBoardItemIDs.isEmpty {
      guard
        await performTaskBoardItemDeletion(
          ids: taskBoardItemIDs,
          using: client,
          presentsSuccessFeedback: false
        )
      else {
        return false
      }
    }

    for group in inboxGroups {
      guard
        await deleteTasks(
          sessionID: group.sessionID,
          taskIDs: group.taskIDs,
          actorID: "harness-app"
        )
      else {
        return false
      }
    }

    presentSuccessFeedback(
      targets.count == 1 ? "Deleted task" : "Deleted \(targets.count) tasks"
    )
    return true
  }

  @discardableResult
  public func deleteTaskBoardItems(ids: [String]) async -> Bool {
    await deleteTaskBoardItems(ids: ids, presentsSuccessFeedback: true)
  }

  private func deleteTaskBoardItems(
    ids: [String],
    presentsSuccessFeedback: Bool
  ) async -> Bool {
    let ids = orderedUniqueDeletionTaskIDs(ids)
    guard let client, !ids.isEmpty, !isTaskBoardBusy else {
      return false
    }
    beginTaskBoardAction()
    defer { endTaskBoardAction() }
    return await performTaskBoardItemDeletion(
      ids: ids,
      using: client,
      presentsSuccessFeedback: presentsSuccessFeedback
    )
  }

  private func performTaskBoardItemDeletion(
    ids: [String],
    using client: any HarnessMonitorClientProtocol,
    presentsSuccessFeedback: Bool
  ) async -> Bool {
    beginDaemonAction()
    defer { endDaemonAction() }

    var deletedIDs: Set<String> = []
    var firstFailure: (index: Int, error: any Error)?
    for (index, id) in ids.enumerated() {
      do {
        _ = try await Self.measureOperation {
          try await client.deleteTaskBoardItem(id: id)
        }
        recordRequestSuccess()
        deletedIDs.insert(id)
      } catch {
        firstFailure = (index, error)
        break
      }
    }

    globalTaskBoardItems.removeAll { deletedIDs.contains($0.id) }
    await refreshTaskBoardDashboardSnapshot(using: client)
    if let firstFailure {
      presentFailureFeedback(
        taskBoardDeletionFailureMessage(
          total: ids.count,
          succeeded: deletedIDs.count,
          failedIndex: firstFailure.index,
          error: firstFailure.error
        )
      )
      return false
    }
    if presentsSuccessFeedback {
      presentSuccessFeedback(
        ids.count == 1 ? "Deleted task board item" : "Deleted \(ids.count) task board items"
      )
    }
    return true
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
            + "Stopped after a failure with \(remaining) not attempted"
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

  private func orderedUniqueTaskBoardDeletionTargets(
    _ targets: [TaskBoardDeletionTarget]
  ) -> [TaskBoardDeletionTarget] {
    var seenIDs: Set<String> = []
    return targets.filter { seenIDs.insert($0.id).inserted }
  }

  private func taskBoardInboxDeletionGroups(
    _ targets: [TaskBoardDeletionTarget]
  ) -> [(sessionID: String, taskIDs: [String])] {
    var groups: [(sessionID: String, taskIDs: [String])] = []
    var groupIndexBySessionID: [String: Int] = [:]
    for target in targets {
      guard case .inboxTask(let sessionID, let taskID, _) = target else { continue }
      if let index = groupIndexBySessionID[sessionID] {
        groups[index].taskIDs.append(taskID)
      } else {
        groupIndexBySessionID[sessionID] = groups.count
        groups.append((sessionID: sessionID, taskIDs: [taskID]))
      }
    }
    return groups
  }

  private func taskBoardDeletionActionIsAvailable(actionName: String) -> Bool {
    if isBusy || isTaskBoardBusy {
      presentFailureFeedback(
        "\(actionName) is unavailable because another action is already in progress. "
          + "Try again when it finishes"
      )
      return false
    }
    if isSessionReadOnly {
      presentFailureFeedback(readOnlySessionAccessMessage)
      return false
    }
    guard client != nil else {
      presentFailureFeedback(
        "The daemon action channel is unavailable. Refresh the session and try again"
      )
      return false
    }
    return canDeleteTaskBoardTargets
  }

  private func taskBoardDeletionFailureMessage(
    total: Int,
    succeeded: Int,
    failedIndex: Int,
    error: any Error
  ) -> String {
    guard total > 1 else {
      return "Task board item could not be deleted: \(error.localizedDescription)"
    }
    let remaining = total - failedIndex - 1
    let unattemptedSuffix: String
    if remaining == 0 {
      unattemptedSuffix = ""
    } else {
      let noun = remaining == 1 ? "item was" : "items were"
      unattemptedSuffix = " \(remaining) \(noun) not attempted."
    }
    return """
      Deleted \(succeeded) of \(total) task board items. Stopped after a failure.\
      \(unattemptedSuffix) \(error.localizedDescription)
      """
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
        "Task deleted, but \(expectedNoteCount) local workspace \(noteNoun) could not be removed"
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
        action: "Task note count could not be loaded",
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
        action: "Task note changes could not be saved",
        underlyingError: error
      )
      return false
    }
  }
}
