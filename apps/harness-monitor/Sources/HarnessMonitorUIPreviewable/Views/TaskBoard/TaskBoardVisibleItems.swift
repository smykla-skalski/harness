import HarnessMonitorKit

enum TaskBoardVisibleItems {
  static func visibleItemsPreservingOrder(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { TaskBoardInboxLane(taskBoardItem: $0) != nil && $0.deletedAt == nil }
  }
}
