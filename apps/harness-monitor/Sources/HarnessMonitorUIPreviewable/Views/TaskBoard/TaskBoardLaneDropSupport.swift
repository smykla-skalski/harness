import HarnessMonitorKit

/// Main-actor snapshot used only when a move is delivered. Keeping the
/// mutable lookup behind a stable reference lets every lane validate against
/// the latest rendered inbox cards without making each lane diff the board's
/// whole inbox dictionary.
@MainActor
final class TaskBoardLiveInboxItems: Equatable {
  private var itemsByID: [TaskBoardCardID: TaskBoardInboxItem] = [:]
  private var sourceItems: [TaskBoardInboxItem]?

  nonisolated static func == (lhs: TaskBoardLiveInboxItems, rhs: TaskBoardLiveInboxItems) -> Bool {
    lhs === rhs
  }

  func replace(with itemsByID: [TaskBoardCardID: TaskBoardInboxItem]) {
    sourceItems = nil
    self.itemsByID = itemsByID
  }

  func replace(with items: [TaskBoardInboxItem]) {
    sourceItems = items
    itemsByID = Dictionary(
      items.map { item in
        (
          .inbox(sessionID: item.session.sessionId, taskID: item.task.taskId),
          item
        )
      },
      uniquingKeysWith: { first, _ in first }
    )
  }

  func replaceIfChanged(with items: [TaskBoardInboxItem]) {
    guard sourceItems != items else { return }
    replace(with: items)
  }

  func item(sessionID: String, taskID: String) -> TaskBoardInboxItem? {
    itemsByID[.inbox(sessionID: sessionID, taskID: taskID)]
  }
}

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
