import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

enum TaskBoardCardDragItem: Codable, Equatable, Sendable, Identifiable {
  case api(itemID: String, status: TaskBoardStatus)
  case inbox(
    sessionID: String,
    taskID: String,
    status: TaskStatus,
    sourceLaneRawValue: String
  )

  var id: TaskBoardCardID {
    switch self {
    case .api(let itemID, _):
      .api(itemID)
    case .inbox(let sessionID, let taskID, _, _):
      .inbox(sessionID: sessionID, taskID: taskID)
    }
  }

  var sourceLane: TaskBoardInboxLane? {
    switch self {
    case .api(_, let status):
      TaskBoardInboxLane(status: status)
    case .inbox(_, _, _, let sourceLaneRawValue):
      TaskBoardInboxLane(rawValue: sourceLaneRawValue)
    }
  }

  func accepts(destination: TaskBoardInboxLane) -> Bool {
    guard let sourceLane, sourceLane != destination else {
      return false
    }
    switch self {
    case .api:
      return true
    case .inbox:
      return destination.acceptsTaskBoardInboxCardDrop
    }
  }
}

struct TaskBoardCardDragPayload: Codable, Transferable, Identifiable, Sendable {
  let id: TaskBoardCardID
  let items: [TaskBoardCardDragItem]

  init(item: TaskBoardCardDragItem) {
    id = item.id
    items = [item]
  }

  init(primaryCardID: TaskBoardCardID, items: [TaskBoardCardDragItem]) {
    id = primaryCardID
    self.items = items
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .harnessMonitorTaskBoardCard)
  }
}

extension UTType {
  static let harnessMonitorTaskBoardCard = UTType(
    exportedAs: "io.harnessmonitor.task-board-card",
    conformingTo: .json
  )
}

extension TaskBoardInboxLane {
  fileprivate var acceptsTaskBoardInboxCardDrop: Bool {
    switch self {
    case .todo, .inProgress, .inReview, .toReview, .failed:
      true
    case .backlog, .planning, .agenticReview, .testing, .humanRequired:
      false
    }
  }
}
