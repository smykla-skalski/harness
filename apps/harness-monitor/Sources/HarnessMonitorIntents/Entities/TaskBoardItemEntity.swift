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

  private static let symbolByStatus: [TaskBoardStatusEnum: String] = [
    .umbrella: "umbrella",
    .todo: "tray.and.arrow.down",
    .planning: "list.clipboard",
    .inProgress: "arrow.triangle.2.circlepath",
    .agenticReview: "sparkles",
    .testing: "checkmark.shield",
    .inReview: "checkmark.seal",
    .toReview: "doc.text.magnifyingglass",
    .humanRequired: "person.crop.circle.badge.exclamationmark",
    .failed: "exclamationmark.triangle",
    .done: "checkmark.circle.fill",
  ]

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
      subtitle: LocalizedStringResource(stringLiteral: status.daemonValue.title),
      image: Self.image(for: status)
    )
  }

  /// Status-driven SF Symbol so the Shortcuts picker can disambiguate
  /// task-board items at a glance instead of forcing the user to read
  /// each row's status subtitle. The system tints the symbol based on
  /// context (light/dark/monochrome) for free
  static func image(for status: TaskBoardStatusEnum) -> DisplayRepresentation.Image {
    let symbol = symbolByStatus[status] ?? "circle"
    return DisplayRepresentation.Image(systemName: symbol)
  }
}
