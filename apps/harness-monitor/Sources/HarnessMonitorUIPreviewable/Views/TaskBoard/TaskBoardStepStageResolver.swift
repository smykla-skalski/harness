import Foundation
import HarnessMonitorKit

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
        whatNext: whatNext(for: .noTarget, item: nil, record: nil),
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
      whatNext: whatNext(for: stage, item: item, record: inputs.latestRecord),
      primaryAction: primaryAction(for: stage, item: item, record: inputs.latestRecord),
      inlineLinks: inlineLinks(for: stage, item: item)
    )
  }

  /// The linked task's status, when an evaluation record exists, decides the
  /// stage so the wizard tracks reality before Evaluate applies the matching
  /// board transition. Board status is only the fallback when no record exists.
  static func stage(
    for item: TaskBoardItem,
    record: TaskBoardEvaluationRecord?,
    hasPicked: Bool,
    hasDelivered: Bool
  ) -> TaskBoardStepStage {
    if let task = record?.taskStatus {
      return stage(
        forTask: task,
        item: item,
        changesRequested: record?.outcome == .reviewChangesRequested
      )
    }
    return stage(forBoard: item, hasPicked: hasPicked, hasDelivered: hasDelivered)
  }

  private static func stage(
    forTask task: TaskStatus,
    item: TaskBoardItem,
    changesRequested: Bool
  ) -> TaskBoardStepStage {
    switch task {
    case .done: .done
    case .blocked: .blocked
    case .inReview: changesRequested ? .changesRequested : .inReview
    case .awaitingReview: .awaitingReview
    case .open, .inProgress: isAwaitingDelivery(item) ? .readyToDeliver : .workerRunning
    }
  }

  private static func stage(
    forBoard item: TaskBoardItem,
    hasPicked: Bool,
    hasDelivered: Bool
  ) -> TaskBoardStepStage {
    switch item.status {
    case .done: return .done
    case .failed, .blocked: return .blocked
    case .inReview: return .inReview
    case .toReview: return .awaitingReview
    case .inProgress: return isAwaitingDelivery(item) ? .readyToDeliver : .workerRunning
    default:
      if hasDelivered { return .workerRunning }
      return hasPicked ? .readyToDeliver : .readyToPick
    }
  }

  /// A held dispatch persisted as in-progress but not yet delivered. Step Mode
  /// offers Deliver so a delivery refused during policy revalidation can be
  /// retried once the grant is resolved, instead of an Evaluate that does nothing.
  private static func isAwaitingDelivery(_ item: TaskBoardItem) -> Bool {
    item.workflow?.currentStepId == "awaiting_delivery"
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
    item: TaskBoardItem,
    record: TaskBoardEvaluationRecord?
  ) -> TaskBoardStepPrimaryAction? {
    switch stage {
    case .noTarget: .sync
    case .readyToPick: .pick
    case .readyToDeliver: .deliver
    // Blocked keeps Evaluate so re-evaluating after the block is resolved works.
    case .workerRunning, .awaitingReview, .inReview, .changesRequested, .blocked: .evaluate
    case .done: isFinished(item, record) ? nil : .complete
    }
  }

  /// The board reached Done, so no further action is needed. Uses the freshest
  /// board status: the item's own or the last evaluation record's.
  private static func isFinished(
    _ item: TaskBoardItem?,
    _ record: TaskBoardEvaluationRecord?
  ) -> Bool {
    item?.status == .done || record?.boardStatus == .done
  }

  private static func inlineLinks(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem
  ) -> [TaskBoardStepInlineLink] {
    let links = availableLinks(for: item)
    switch stage {
    case .workerRunning: return links.watch
    case .awaitingReview: return links.watch + links.task
    case .inReview, .changesRequested: return links.task + links.pullRequest
    case .done: return links.pullRequest
    case .blocked: return links.task
    case .noTarget, .readyToPick, .readyToDeliver: return []
    }
  }

  private struct AvailableLinks {
    let watch: [TaskBoardStepInlineLink]
    let task: [TaskBoardStepInlineLink]
    let pullRequest: [TaskBoardStepInlineLink]
  }

  /// The links each capability enables, as ready-to-concatenate fragments.
  private static func availableLinks(for item: TaskBoardItem) -> AvailableLinks {
    // Matches openReview: a linked session task or, failing that, a GitHub URL.
    let canOpenTask = item.hasLinkedSessionTask || item.taskBoardGitHubURL != nil
    return AvailableLinks(
      watch: item.sessionId != nil ? [.watch] : [],
      task: canOpenTask ? [.openTask] : [],
      pullRequest: validURL(item.workflow?.prUrl) != nil ? [.openPullRequest] : []
    )
  }

  /// A non-empty, parseable URL. Shared by the link gate and the tap handler so
  /// the two never disagree about whether a URL is usable.
  static func validURL(_ raw: String?) -> URL? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    return URL(string: raw)
  }

  private static func whatNext(
    for stage: TaskBoardStepStage,
    item: TaskBoardItem?,
    record: TaskBoardEvaluationRecord?
  ) -> String {
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
      isFinished(item, record)
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
      isFinished(item, record)
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
