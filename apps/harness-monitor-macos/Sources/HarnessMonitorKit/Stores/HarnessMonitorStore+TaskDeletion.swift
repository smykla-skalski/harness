import Foundation
import SwiftData

extension HarnessMonitorStore {
  public func requestDeleteTaskConfirmation(
    sessionID: String,
    taskID: String,
    taskTitle: String
  ) {
    let actionName = "Delete task"
    guard prepareSessionAction(named: actionName, sessionID: sessionID) != nil else { return }
    guard let actorID = actionActor(for: "harness-app", actionName: actionName) else {
      return
    }
    pendingConfirmation = .deleteTask(
      sessionID: sessionID,
      taskID: taskID,
      taskTitle: taskTitle,
      actorID: actorID,
      noteCount: taskUserNoteCount(taskID: taskID, sessionID: sessionID)
    )
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
    let didDeleteNotes = deleteTaskUserNotes(
      taskID: taskID,
      sessionID: sessionID,
      requiresPurge: expectedNoteCount > 0
    )
    if !didDeleteNotes, expectedNoteCount > 0 {
      presentFailureFeedback(
        "Task deleted, but \(expectedNoteCount) local workspace \(expectedNoteCount == 1 ? "note could not be" : "notes could not be") removed."
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

  private func taskUserNoteCount(taskID: String, sessionID: String) -> Int {
    guard let modelContext, persistenceError == nil else {
      return 0
    }
    do {
      return try modelContext.fetch(taskUserNoteDescriptor(taskID: taskID, sessionID: sessionID))
        .count
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
  ) -> Bool {
    guard let modelContext, persistenceError == nil else {
      return !requiresPurge
    }
    do {
      let notes = try modelContext.fetch(taskUserNoteDescriptor(taskID: taskID, sessionID: sessionID))
      guard !notes.isEmpty else {
        return true
      }
      for note in notes {
        modelContext.delete(note)
      }
      try modelContext.save()
      return true
    } catch {
      modelContext.rollback()
      recordPersistenceFailure(
        action: "Task note changes could not be saved.",
        underlyingError: error
      )
      return false
    }
  }

  private func taskUserNoteDescriptor(
    taskID: String,
    sessionID: String
  ) -> FetchDescriptor<UserNote> {
    let targetKind = "task"
    let targetID = taskID
    let selectedSessionID = sessionID
    return FetchDescriptor<UserNote>(
      predicate: #Predicate<UserNote> { note in
        note.targetKind == targetKind
          && note.targetId == targetID
          && note.sessionId == selectedSessionID
      }
    )
  }
}
