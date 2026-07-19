import Foundation
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

  func nodeState(current: TaskBoardStepColumn?, isBlocked: Bool) -> TaskBoardStepNodeState {
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

/// Pure derivation of the Step Mode stage. Mirrors the daemon reconciliation in
/// `src/task_board/evaluation.rs`: the linked task's status drives the stage and
/// Evaluate is the action that advances the board to match it.
enum TaskBoardStepStageResolver {
  static func plan(for inputs: TaskBoardStepStageInputs) -> TaskBoardStepStagePlan {
    guard let item = inputs.item else {
      return TaskBoardStepStagePlan(
        stage: .noTarget,
        column: nil,
        isBlockedColumn: false,
        whatHappened: nil,
        whatNext: whatNext(for: .noTarget, item: nil),
        primaryAction: .sync,
        inlineLinks: []
      )
    }
    let stage = stage(
      for: item,
      record: inputs.latestRecord,
      hasPicked: inputs.hasPicked,
      hasDelivered: inputs.hasDelivered
    )
    return TaskBoardStepStagePlan(
      stage: stage,
      column: column(for: stage, item: item),
      isBlockedColumn: stage == .blocked,
      whatHappened: whatHappened(for: stage, item: item, record: inputs.latestRecord),
      whatNext: whatNext(for: stage, item: item),
      primaryAction: primaryAction(for: stage, item: item),
      inlineLinks: inlineLinks(for: stage, item: item)
    )
  }

  /// The freshest linked-task status wins, so the wizard tracks reality even
  /// before Evaluate applies the matching board transition. Precedence runs
  /// end-to-start of the pipeline so the most advanced signal decides the stage.
  static func stage(
    for item: TaskBoardItem,
    record: TaskBoardEvaluationRecord?,
    hasPicked: Bool,
    hasDelivered: Bool
  ) -> TaskBoardStepStage {
    let task = record?.taskStatus
    if item.status == .done || task == .done { return .done }
    if item.status == .failed || item.status == .blocked || task == .blocked { return .blocked }
    if task == .inReview || item.status == .inReview {
      return record?.outcome == .reviewChangesRequested ? .changesRequested : .inReview
    }
    if task == .awaitingReview || item.status == .toReview { return .awaitingReview }
    if item.status == .inProgress || task == .inProgress || task == .open || hasDelivered {
      return .workerRunning
    }
    return hasPicked ? .readyToDeliver : .readyToPick
  }

  private static func column(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem
  ) -> TaskBoardStepColumn? {
    switch stage {
    case .noTarget: nil
    case .readyToPick, .readyToDeliver: .todo
    case .workerRunning: .inProgress
    case .awaitingReview: .toReview
    case .inReview, .changesRequested: .inReview
    case .done: .done
    case .blocked: boardColumn(item.status) ?? .inProgress
    }
  }

  private static func boardColumn(_ status: TaskBoardStatus) -> TaskBoardStepColumn? {
    switch status {
    case .todo, .backlog, .planning, .new, .planReview: .todo
    case .inProgress, .testing: .inProgress
    case .toReview, .agenticReview, .humanRequired, .needsYou: .toReview
    case .inReview: .inReview
    case .done: .done
    case .failed, .blocked, .unknown: nil
    }
  }

  private static func primaryAction(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem
  ) -> TaskBoardStepPrimaryAction? {
    switch stage {
    case .noTarget: .sync
    case .readyToPick: .pick
    case .readyToDeliver: .deliver
    case .workerRunning, .awaitingReview, .inReview, .changesRequested: .evaluate
    case .blocked: nil
    case .done: item.status == .done ? nil : .complete
    }
  }

  private static func inlineLinks(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem
  ) -> [TaskBoardStepInlineLink] {
    let hasSession = item.sessionId != nil
    let hasTask = item.sessionId != nil && item.workItemId != nil
    let hasPullRequest = item.workflow?.prUrl != nil
    var links: [TaskBoardStepInlineLink] = []
    switch stage {
    case .workerRunning:
      if hasSession { links.append(.watch) }
    case .awaitingReview:
      if hasSession { links.append(.watch) }
      if hasTask { links.append(.openTask) }
    case .inReview, .changesRequested:
      if hasTask { links.append(.openTask) }
      if hasPullRequest { links.append(.openPullRequest) }
    case .done:
      if hasPullRequest { links.append(.openPullRequest) }
    case .blocked:
      if hasTask { links.append(.openTask) }
    case .noTarget, .readyToPick, .readyToDeliver:
      break
    }
    return links
  }

  private static func whatNext(for stage: TaskBoardStepStage, item: TaskBoardItem?) -> String {
    switch stage {
    case .noTarget:
      "Sync pulls the latest external sources so a Todo item becomes ready to work"
    case .readyToPick:
      "Pick loads the exact spawn prompt so you can read it before any worker starts"
    case .readyToDeliver:
      "Deliver spawns the managed worker with the prompt shown below"
    case .workerRunning:
      "Evaluate checks the worker and moves the item to review once its task finishes"
    case .awaitingReview:
      "Evaluate signals the reviewer and moves the item into review"
    case .inReview:
      "Evaluate reads the review verdict; an approval finishes the item"
    case .changesRequested:
      "Address the requested changes, then Evaluate re-checks the review"
    case .blocked:
      "Resolve the block on the linked task, then re-evaluate the item"
    case .done:
      item?.status == .done
        ? "This item reached Done with nothing left to authorize"
        : "Complete moves the board item into Done"
    }
  }

  private static func whatHappened(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem,
    record: TaskBoardEvaluationRecord?
  ) -> String? {
    switch stage {
    case .noTarget:
      nil
    case .readyToPick:
      "This is the next Todo item the automation would work"
    case .readyToDeliver:
      "Loaded the exact spawn prompt for this item"
    case .workerRunning:
      "The worker is running against this item"
    case .awaitingReview:
      "The worker finished; its task is awaiting review"
    case .inReview:
      "The reviewer is reviewing the delivered work"
    case .changesRequested:
      reasonText(item: item, record: record).map { "The reviewer requested changes: \($0)" }
        ?? "The reviewer requested changes to the delivered work"
    case .blocked:
      reasonText(item: item, record: record).map { "This item is blocked: \($0)" }
        ?? "This item is blocked and needs a human decision"
    case .done:
      item.status == .done
        ? "This item reached Done"
        : "The work is approved and its task is done"
    }
  }

  private static func reasonText(
    item: TaskBoardItem,
    record: TaskBoardEvaluationRecord?
  ) -> String? {
    for candidate in [record?.reason, item.workflow?.lastError] {
      if let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
        return text
      }
    }
    return nil
  }
}
