import HarnessMonitorKit

enum TaskBoardLaneListRow: Identifiable {
  enum RowID: Hashable {
    case decision(String)
    case api(String)
    case inbox(sessionID: String, taskID: String)
  }

  case decision(Decision)
  case api(TaskBoardItem)
  case inbox(TaskBoardInboxItem)

  var id: RowID {
    switch self {
    case .decision(let decision):
      .decision(decision.id)
    case .api(let item):
      .api(item.id)
    case .inbox(let item):
      .inbox(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId
      )
    }
  }

  var cardID: TaskBoardCardID? {
    switch self {
    case .decision:
      nil
    case .api(let item):
      .api(item.id)
    case .inbox(let item):
      .inbox(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId
      )
    }
  }

  var isAPI: Bool {
    if case .api = self {
      true
    } else {
      false
    }
  }
}
