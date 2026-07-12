import Foundation

public enum TaskBoardDeletionTarget: Equatable, Hashable, Identifiable, Sendable {
  case taskBoardItem(id: String, title: String)
  case inboxTask(sessionID: String, taskID: String, title: String)

  public var id: String {
    switch self {
    case .taskBoardItem(let id, _):
      "task-board-item:\(id)"
    case .inboxTask(let sessionID, let taskID, _):
      "inbox-task:\(sessionID):\(taskID)"
    }
  }

  public var title: String {
    switch self {
    case .taskBoardItem(_, let title), .inboxTask(_, _, let title):
      title
    }
  }

  public init(taskBoardItem: TaskBoardItem) {
    self = .taskBoardItem(id: taskBoardItem.id, title: taskBoardItem.title)
  }

  public init(inboxTask: TaskBoardInboxItem) {
    self = .inboxTask(
      sessionID: inboxTask.session.sessionId,
      taskID: inboxTask.task.taskId,
      title: inboxTask.task.title
    )
  }
}
