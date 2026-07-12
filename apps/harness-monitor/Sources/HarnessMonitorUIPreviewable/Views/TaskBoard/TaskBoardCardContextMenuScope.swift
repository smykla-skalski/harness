struct TaskBoardCardContextMenuScope: Equatable, Sendable {
  let primaryID: TaskBoardCardID
  let cardIDs: [TaskBoardCardID]

  var count: Int { cardIDs.count }
  var isSingle: Bool { count == 1 }

  var copyIDsLabel: String {
    isSingle ? "Copy Task ID" : "Copy \(count) Task IDs"
  }

  var deleteLabel: String {
    isSingle ? "Delete Task..." : "Delete \(count) Tasks..."
  }

  var clipboardText: String {
    cardIDs.map(\.taskID).joined(separator: "\n")
  }

  static func resolve(
    menuSelection: Set<TaskBoardCardID>,
    selectedIDs: Set<TaskBoardCardID>,
    orderedVisibleIDs: [TaskBoardCardID]
  ) -> Self? {
    guard let menuTarget = ordered(menuSelection, using: orderedVisibleIDs).first else {
      return nil
    }
    let scopedIDs = selectedIDs.contains(menuTarget) ? selectedIDs : menuSelection
    let orderedIDs = ordered(scopedIDs, using: orderedVisibleIDs)
    guard !orderedIDs.isEmpty else {
      return nil
    }
    return Self(primaryID: menuTarget, cardIDs: orderedIDs)
  }

  private static func ordered(
    _ ids: Set<TaskBoardCardID>,
    using orderedVisibleIDs: [TaskBoardCardID]
  ) -> [TaskBoardCardID] {
    let visible = orderedVisibleIDs.filter(ids.contains)
    guard visible.count < ids.count else {
      return visible
    }
    let visibleSet = Set(visible)
    let remaining = ids.subtracting(visibleSet).sorted { $0.sortKey < $1.sortKey }
    return visible + remaining
  }
}

extension TaskBoardCardID {
  fileprivate var taskID: String {
    switch self {
    case .api(let itemID):
      itemID
    case .inbox(_, let taskID):
      taskID
    }
  }

  fileprivate var sortKey: String {
    switch self {
    case .api(let itemID):
      "api:\(itemID)"
    case .inbox(let sessionID, let taskID):
      "inbox:\(sessionID):\(taskID)"
    }
  }
}
