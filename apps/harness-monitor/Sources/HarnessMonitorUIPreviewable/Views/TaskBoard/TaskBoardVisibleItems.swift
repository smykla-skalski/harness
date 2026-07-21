import HarnessMonitorKit

enum TaskBoardVisibleItems {
  static func sorted(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { TaskBoardInboxLane(taskBoardItem: $0) != nil && $0.deletedAt == nil }
      .sorted { left, right in
        if left.priority != right.priority {
          return priorityRank(left.priority) > priorityRank(right.priority)
        }
        if left.updatedAt != right.updatedAt {
          return left.updatedAt > right.updatedAt
        }
        return left.id < right.id
      }
  }

  private static func priorityRank(_ priority: TaskBoardPriority) -> Int {
    switch priority {
    case .critical:
      3
    case .high:
      2
    case .medium:
      1
    case .low:
      0
    }
  }
}
