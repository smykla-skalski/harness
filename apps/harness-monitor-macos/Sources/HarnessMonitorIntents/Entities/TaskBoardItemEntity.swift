import AppIntents
import Foundation
import HarnessMonitorKit

public struct TaskBoardItemEntity: AppEntity, Identifiable, Sendable {
  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Task", numericFormat: "\(placeholder: .int) tasks")
  }

  public static var defaultQuery: TaskBoardItemQuery { TaskBoardItemQuery() }

  public let id: String
  public let title: String
  public let status: TaskBoardStatusEnum
  public let priority: String
  public let projectId: String?

  public init(
    id: String,
    title: String,
    status: TaskBoardStatusEnum,
    priority: String,
    projectId: String?
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.priority = priority
    self.projectId = projectId
  }

  public init(from item: TaskBoardItem) {
    self.init(
      id: item.id,
      title: item.title,
      status: TaskBoardStatusEnum(daemonValue: item.status),
      priority: item.priority.title,
      projectId: item.projectId
    )
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: title),
      subtitle: LocalizedStringResource(stringLiteral: status.daemonValue.title)
    )
  }
}
