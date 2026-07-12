import HarnessMonitorKit

struct TaskBoardCardDropPlan: Equatable {
  let items: [TaskBoardCardDragItem]
  let destination: TaskBoardInboxLane

  static func resolve(
    _ payloads: [TaskBoardCardDragPayload],
    to destination: TaskBoardInboxLane
  ) -> Self? {
    var seenIDs: Set<TaskBoardCardID> = []
    let uniqueItems = payloads.flatMap(\.items).filter { item in
      seenIDs.insert(item.id).inserted
    }
    let items = uniqueItems.filter { $0.sourceLane != destination }
    guard !items.isEmpty, items.allSatisfy({ $0.accepts(destination: destination) }) else {
      return nil
    }
    return Self(items: items, destination: destination)
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

struct TaskBoardCardDropSignature: Equatable {
  let cardIDs: [TaskBoardCardID]
  let destination: TaskBoardInboxLane
}
