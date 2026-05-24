import AppIntents
import Foundation
import HarnessMonitorKit

public struct ListTaskBoardItemsIntent: AppIntent {
  public static var title: LocalizedStringResource { "List Task Board Items" }
  public static var description: IntentDescription {
    IntentDescription(
      """
      Return Task Board items, optionally filtered to a single workflow \
      status (Ready, In Progress, Blocked, …).
      """,
      categoryName: "Task Board",
      searchKeywords: ["task", "todo", "board", "list"],
      resultValueName: "Task Board Items"
    )
  }

  @Parameter(
    title: "Status",
    description: "Optional status filter. Omit to return every task on the board"
  )
  public var status: TaskBoardStatusEnum?

  let source: TaskBoardItemSource

  public init() {
    self.source = DaemonTaskBoardItemSource()
  }

  init(status: TaskBoardStatusEnum?, source: TaskBoardItemSource) {
    self.source = source
    self.status = status
  }

  public func perform() async throws -> some IntentResult & ReturnsValue<[TaskBoardItemEntity]> {
    let entities = try await resolveEntities()
    return .result(value: entities)
  }

  func resolveEntities() async throws -> [TaskBoardItemEntity] {
    let items = try await source.list(status: status?.daemonValue)
    return items.map(TaskBoardItemEntity.init(from:))
  }
}
