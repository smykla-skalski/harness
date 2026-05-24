import AppIntents
import Foundation
import HarnessMonitorKit

public enum TaskBoardStatusEnum: String, AppEnum, Sendable {
  case new
  case planning
  case planReview
  case needsYou
  case todo
  case inProgress
  case inReview
  case done
  case blocked

  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Task Status")
  }

  public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
    [
      .new: DisplayRepresentation(title: "New"),
      .planning: DisplayRepresentation(title: "Planning"),
      .planReview: DisplayRepresentation(title: "Plan Review"),
      .needsYou: DisplayRepresentation(title: "Needs You"),
      .todo: DisplayRepresentation(title: "Ready"),
      .inProgress: DisplayRepresentation(title: "In Progress"),
      .inReview: DisplayRepresentation(title: "In Review"),
      .done: DisplayRepresentation(title: "Done"),
      .blocked: DisplayRepresentation(title: "Blocked"),
    ]
  }

  public init(daemonValue: TaskBoardStatus) {
    switch daemonValue {
    case .new: self = .new
    case .planning: self = .planning
    case .planReview: self = .planReview
    case .needsYou: self = .needsYou
    case .todo: self = .todo
    case .inProgress: self = .inProgress
    case .inReview: self = .inReview
    case .done: self = .done
    case .blocked: self = .blocked
    case .unknown: self = .new
    }
  }

  public var daemonValue: TaskBoardStatus {
    switch self {
    case .new: .new
    case .planning: .planning
    case .planReview: .planReview
    case .needsYou: .needsYou
    case .todo: .todo
    case .inProgress: .inProgress
    case .inReview: .inReview
    case .done: .done
    case .blocked: .blocked
    }
  }
}
