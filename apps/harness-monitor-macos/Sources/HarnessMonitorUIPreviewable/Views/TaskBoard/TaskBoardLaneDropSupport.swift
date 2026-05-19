import HarnessMonitorKit

enum TaskBoardLaneDropPolicy {
  static func moveFirstPayload(
    _ payloads: [TaskBoardItemDragPayload],
    to destination: TaskBoardInboxLane,
    move: (String, TaskBoardInboxLane) -> Bool
  ) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    guard let sourceLane = payload.sourceLane, sourceLane != destination else {
      return false
    }
    return move(payload.itemID, destination)
  }
}

struct TaskBoardDropDeduper<Key: Equatable> {
  private var handledKey: Key?

  mutating func perform(_ key: Key, move: () -> Bool) -> Bool {
    guard handledKey != key else {
      return true
    }
    let moved = move()
    if moved {
      handledKey = key
    }
    return moved
  }

  mutating func reset() {
    handledKey = nil
  }
}

struct TaskBoardItemDropSignature: Equatable {
  let itemID: String
  let destination: TaskBoardInboxLane
}

struct TaskBoardInboxItemDropSignature: Equatable {
  let sessionID: String
  let taskID: String
  let destination: TaskBoardInboxLane
}

enum TaskBoardInboxDropPolicy {
  static func moveFirstPayload(
    _ payloads: [TaskBoardInboxItemDragPayload],
    to destination: TaskBoardInboxLane,
    move: (TaskBoardInboxItemDragPayload, TaskBoardInboxLane) -> Bool
  ) -> Bool {
    guard let payload = payloads.first else {
      return false
    }
    guard let sourceLane = payload.sourceLane, sourceLane != destination else {
      return false
    }
    return move(payload, destination)
  }
}
