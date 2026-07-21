import HarnessMonitorKit

/// Umbrella/child navigation is view-layer only: both directions resolve from
/// whatever item array the caller already has loaded (typically the store's
/// full `globalTaskBoardItems`, not a project/session-scoped subset), since
/// the daemon sends `parentItemId` on every item already.
enum TaskBoardUmbrellaHierarchy {
  static func children(of parentID: String, in items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { $0.parentItemId == parentID && $0.deletedAt == nil }
      .sorted { lhs, rhs in
        lhs.childOrder != rhs.childOrder ? lhs.childOrder < rhs.childOrder : lhs.id < rhs.id
      }
  }

  static func parent(of item: TaskBoardItem, in items: [TaskBoardItem]) -> TaskBoardItem? {
    guard let parentItemId = item.parentItemId else { return nil }
    return items.first { $0.id == parentItemId && $0.deletedAt == nil }
  }
}

/// A live parent link that fails to resolve is distinct from having no parent
/// at all: the former must say so rather than silently rendering nothing.
enum TaskBoardParentBacklink: Equatable {
  case none
  case resolved(TaskBoardItem)
  case outsideCurrentView(parentItemId: String)

  init(item: TaskBoardItem, loadedItems: [TaskBoardItem]) {
    guard let parentItemId = item.parentItemId else {
      self = .none
      return
    }
    if let parent = TaskBoardUmbrellaHierarchy.parent(of: item, in: loadedItems) {
      self = .resolved(parent)
    } else {
      self = .outsideCurrentView(parentItemId: parentItemId)
    }
  }
}

/// Children this umbrella has direct records for, split by whether the
/// child's own lane is currently collapsed on the board. A collapsed lane
/// hides the card there, so the summary must call that out instead of
/// appearing to have fewer children than it does.
struct TaskBoardUmbrellaChildrenSummary: Equatable {
  let visibleChildren: [TaskBoardItem]
  let hiddenChildren: [TaskBoardItem]

  var hiddenCount: Int { hiddenChildren.count }

  var notShownMessage: String? {
    guard hiddenCount > 0 else { return nil }
    return hiddenCount == 1
      ? "1 child not shown here"
      : "\(hiddenCount) children not shown here"
  }

  static func summarizing(
    _ umbrellaID: String,
    in items: [TaskBoardItem],
    collapsedLanes: Set<TaskBoardInboxLane>
  ) -> TaskBoardUmbrellaChildrenSummary {
    let children = TaskBoardUmbrellaHierarchy.children(of: umbrellaID, in: items)
    var visible: [TaskBoardItem] = []
    var hidden: [TaskBoardItem] = []
    for child in children {
      if let lane = TaskBoardInboxLane(taskBoardItem: child), collapsedLanes.contains(lane) {
        hidden.append(child)
      } else {
        visible.append(child)
      }
    }
    return TaskBoardUmbrellaChildrenSummary(visibleChildren: visible, hiddenChildren: hidden)
  }
}
