import AppIntents
import Foundation
import HarnessMonitorKit

public enum TaskBoardStatusEnum: String, AppEnum, Sendable {
  case umbrella
  case todo
  case planning
  case inProgress
  case agenticReview
  case testing
  case inReview
  case toReview
  case humanRequired
  case failed
  case done

  private static let intentStatusByDaemonStatus: [TaskBoardStatus: Self] = [
    .umbrella: .umbrella,
    .todo: .todo,
    .planning: .planning,
    .inProgress: .inProgress,
    .agenticReview: .agenticReview,
    .testing: .testing,
    .inReview: .inReview,
    .toReview: .toReview,
    .humanRequired: .humanRequired,
    .failed: .failed,
    .done: .done,
    .new: .todo,
    .planReview: .agenticReview,
    .needsYou: .humanRequired,
    .blocked: .failed,
  ]

  public static var typeDisplayRepresentation: TypeDisplayRepresentation {
    .init(name: "Task Status")
  }

  public static var caseDisplayRepresentations: [Self: DisplayRepresentation] {
    [
      .umbrella: DisplayRepresentation(title: "Umbrella"),
      .todo: DisplayRepresentation(title: "Todo"),
      .planning: DisplayRepresentation(title: "Planning"),
      .inProgress: DisplayRepresentation(title: "In Progress"),
      .agenticReview: DisplayRepresentation(title: "Agentic Review"),
      .testing: DisplayRepresentation(title: "Testing"),
      .inReview: DisplayRepresentation(title: "In Review"),
      .toReview: DisplayRepresentation(title: "To Review"),
      .humanRequired: DisplayRepresentation(title: "Human Required"),
      .failed: DisplayRepresentation(title: "Failed"),
      .done: DisplayRepresentation(title: "Done"),
    ]
  }

  public init(daemonValue: TaskBoardStatus) {
    self = Self.intentStatusByDaemonStatus[daemonValue] ?? .todo
  }

  public var daemonValue: TaskBoardStatus {
    switch self {
    case .umbrella: .umbrella
    case .todo: .todo
    case .planning: .planning
    case .inProgress: .inProgress
    case .agenticReview: .agenticReview
    case .testing: .testing
    case .inReview: .inReview
    case .toReview: .toReview
    case .humanRequired: .humanRequired
    case .failed: .failed
    case .done: .done
    }
  }
}
