import HarnessMonitorKit

/// Board lifecycle columns shown in the Step Mode progress rail.
enum TaskBoardStepColumn: String, CaseIterable, Identifiable, Sendable {
  case todo
  case inProgress
  case toReview
  case inReview
  case done

  var id: String { rawValue }

  var title: String {
    switch self {
    case .todo: "Todo"
    case .inProgress: "In Progress"
    case .toReview: "To Review"
    case .inReview: "In Review"
    case .done: "Done"
    }
  }

  /// Position used to derive done / current / upcoming node states.
  var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }

  /// Forward-looking summary shown when the user taps a rail node to read ahead.
  var explanation: String {
    switch self {
    case .todo: "The automation picks the top Todo item and delivers a worker for it"
    case .inProgress: "The delivered worker runs; Evaluate advances the item when its task finishes"
    case .toReview: "The finished work waits for a reviewer; Evaluate signals the reviewer"
    case .inReview: "The reviewer checks the work; Evaluate applies the verdict"
    case .done: "The item is complete once its review is approved"
    }
  }

  func nodeState(current: Self?, isBlocked: Bool) -> TaskBoardStepNodeState {
    guard let current else { return .upcoming }
    if order < current.order { return .done }
    if self == current { return isBlocked ? .failed : .current }
    return .upcoming
  }
}

/// Visual state of a single rail node.
enum TaskBoardStepNodeState: Sendable {
  case done
  case current
  case upcoming
  case failed

  var accessibilityDescription: String {
    switch self {
    case .done: "done"
    case .current: "current step"
    case .upcoming: "upcoming"
    case .failed: "blocked"
    }
  }
}

/// The guided stage the wizard presents, derived from live board, worker, and
/// review signals rather than a fixed step counter.
enum TaskBoardStepStage: String, CaseIterable, Identifiable, Sendable {
  case noTarget
  case readyToPick
  case readyToDeliver
  case workerRunning
  case awaitingReview
  case inReview
  case changesRequested
  case blocked
  case done

  var id: String { rawValue }

  /// Short stage title for the focused card and accessibility.
  var title: String {
    switch self {
    case .noTarget: "No ready item"
    case .readyToPick: "Ready to pick"
    case .readyToDeliver: "Ready to deliver"
    case .workerRunning: "Worker running"
    case .awaitingReview: "Awaiting review"
    case .inReview: "In review"
    case .changesRequested: "Changes requested"
    case .blocked: "Blocked"
    case .done: "Done"
    }
  }
}

/// The authorize-and-run action the current stage's Next button triggers. Each
/// case maps to an existing manual-step operation.
enum TaskBoardStepPrimaryAction: String, Equatable, Sendable {
  case sync
  case pick
  case deliver
  case evaluate
  case complete

  var buttonTitle: String {
    switch self {
    case .sync: "Sync external sources"
    case .pick: "Pick Top"
    case .deliver: "Deliver Live"
    case .evaluate: "Evaluate Live"
    case .complete: "Complete"
    }
  }

  /// Pick is a read-only preview; every board mutation confirms first.
  var needsConfirmation: Bool {
    switch self {
    case .pick: false
    case .sync, .deliver, .evaluate, .complete: true
    }
  }
}

/// Secondary navigation links surfaced inside a stage. These open a window and
/// never mutate the board.
enum TaskBoardStepInlineLink: String, CaseIterable, Identifiable, Sendable {
  case watch
  case openTask
  case openPullRequest

  var id: String { rawValue }

  var title: String {
    switch self {
    case .watch: "Watch worker"
    case .openTask: "Open task"
    case .openPullRequest: "Open pull request"
    }
  }
}

/// Live signals the resolver maps to a stage.
struct TaskBoardStepStageInputs {
  var item: TaskBoardItem?
  var latestRecord: TaskBoardEvaluationRecord?
  var hasPicked: Bool
  var hasDelivered: Bool

  init(
    item: TaskBoardItem?,
    latestRecord: TaskBoardEvaluationRecord? = nil,
    hasPicked: Bool = false,
    hasDelivered: Bool = false
  ) {
    self.item = item
    self.latestRecord = latestRecord
    self.hasPicked = hasPicked
    self.hasDelivered = hasDelivered
  }
}

/// The resolved current stage plus everything the card needs to render it.
struct TaskBoardStepStagePlan: Equatable, Sendable {
  var stage: TaskBoardStepStage
  var column: TaskBoardStepColumn?
  var isBlockedColumn: Bool
  var whatHappened: String?
  var whatNext: String
  var primaryAction: TaskBoardStepPrimaryAction?
  var inlineLinks: [TaskBoardStepInlineLink]
}
