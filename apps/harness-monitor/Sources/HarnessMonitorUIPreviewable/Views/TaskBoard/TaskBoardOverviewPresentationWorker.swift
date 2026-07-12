import Foundation
import HarnessMonitorKit
import OSLog

struct TaskBoardOverviewPresentationInput: Equatable, Sendable {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let decisionItems: [DecisionPresentationItem]
  let scopeSessionID: String?
}

struct TaskBoardOverviewPresentation: Equatable, Sendable {
  static let empty = Self(
    taskBoardItems: [],
    taskBoardItemsByID: [:],
    projectLabelResolver: TaskBoardProjectLabelResolver(projectIDs: []),
    apiItemsByLane: [:],
    inboxItemsByLane: [:],
    inboxItemsByID: [:],
    orderedCardIDs: [],
    decisionIDsByLane: [:],
    aggregateNeedsYouCount: 0,
    aggregateOpenCount: 0,
    aggregateReviewCount: 0,
    aggregateBlockedCount: 0,
    aggregateDoneCount: 0
  )

  let taskBoardItems: [TaskBoardItem]
  let taskBoardItemsByID: [String: TaskBoardItem]
  let projectLabelResolver: TaskBoardProjectLabelResolver
  let apiItemsByLane: [TaskBoardInboxLane: [TaskBoardItem]]
  let inboxItemsByLane: [TaskBoardInboxLane: [TaskBoardInboxItem]]
  let inboxItemsByID: [TaskBoardCardID: TaskBoardInboxItem]
  let orderedCardIDs: [TaskBoardCardID]
  let decisionIDsByLane: [TaskBoardInboxLane: [String]]
  let aggregateNeedsYouCount: Int
  let aggregateOpenCount: Int
  let aggregateReviewCount: Int
  let aggregateBlockedCount: Int
  let aggregateDoneCount: Int

  var hasBoardContent: Bool {
    !taskBoardItems.isEmpty
      || inboxItemsByLane.values.contains { !$0.isEmpty }
      || decisionIDsByLane.values.contains { !$0.isEmpty }
  }

  var hasAggregateSummary: Bool {
    aggregateNeedsYouCount != 0
      || aggregateOpenCount != 0
      || aggregateReviewCount != 0
      || aggregateBlockedCount != 0
      || aggregateDoneCount != 0
  }

  func apiItems(in lane: TaskBoardInboxLane) -> [TaskBoardItem] {
    apiItemsByLane[lane] ?? []
  }

  func inboxItems(in lane: TaskBoardInboxLane) -> [TaskBoardInboxItem] {
    inboxItemsByLane[lane] ?? []
  }

  func decisionIDs(in lane: TaskBoardInboxLane) -> [String] {
    decisionIDsByLane[lane] ?? []
  }

  func taskBoardItem(id: String) -> TaskBoardItem? {
    taskBoardItemsByID[id]
  }

  func inboxItem(id: TaskBoardCardID) -> TaskBoardInboxItem? {
    inboxItemsByID[id]
  }
}

actor TaskBoardOverviewPresentationWorker {
  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: TaskBoardOverviewPresentationInput?
  private var cachedOutput = TaskBoardOverviewPresentation.empty

  func compute(input: TaskBoardOverviewPresentationInput) -> TaskBoardOverviewPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let signpostID = Self.signposter.makeSignpostID()
    let interval = Self.signposter.beginInterval(
      "task_board_overview.presentation.compute",
      id: signpostID,
      """
      api=\(input.taskBoardItems.count, privacy: .public) \
      inbox=\(input.snapshot.items.count, privacy: .public) \
      decisions=\(input.decisionItems.count, privacy: .public)
      """
    )
    defer {
      Self.signposter.endInterval(
        "task_board_overview.presentation.compute",
        interval,
        "api_visible=\(self.cachedOutput.taskBoardItems.count, privacy: .public)"
      )
    }

    cachedInput = input
    cachedOutput = Self.presentation(from: input)
    return cachedOutput
  }

  func waitForIdle() async {}

  private static func presentation(
    from input: TaskBoardOverviewPresentationInput
  ) -> TaskBoardOverviewPresentation {
    let scopedTaskBoardItems =
      if let scopeSessionID = input.scopeSessionID {
        input.taskBoardItems.filter { $0.sessionId == scopeSessionID }
      } else {
        input.taskBoardItems
      }
    let taskBoardItems = sortedTaskBoardItems(scopedTaskBoardItems)
    let apiItemsByLane = Dictionary(grouping: taskBoardItems) { item in
      TaskBoardInboxLane(status: item.status) ?? .todo
    }
    let inboxItemsByLane = Dictionary(grouping: input.snapshot.items, by: \.lane)
    let inboxItemsByID = Dictionary(
      uniqueKeysWithValues: input.snapshot.items.map { item in
        (
          TaskBoardCardID.inbox(
            sessionID: item.session.sessionId,
            taskID: item.task.taskId
          ),
          item
        )
      }
    )
    let decisionIDs = sortedOpenDecisionIDs(input.decisionItems)
    let decisionIDsByLane: [TaskBoardInboxLane: [String]] =
      decisionIDs.isEmpty ? [:] : [.humanRequired: decisionIDs]

    let taskBoardNeedsYouCount = apiItemsByLane[.humanRequired]?.count ?? 0
    let taskBoardReviewCount = reviewLanes.reduce(0) { count, lane in
      count + (apiItemsByLane[lane]?.count ?? 0)
    }
    let taskBoardBlockedCount = apiItemsByLane[.failed]?.count ?? 0
    let taskBoardDoneCount = scopedTaskBoardItems.count {
      $0.deletedAt == nil && $0.status == .done
    }
    let taskBoardOpenCount = taskBoardItems.count

    return TaskBoardOverviewPresentation(
      taskBoardItems: taskBoardItems,
      taskBoardItemsByID: Dictionary(uniqueKeysWithValues: taskBoardItems.map { ($0.id, $0) }),
      projectLabelResolver: TaskBoardProjectLabelResolver(
        projectIDs: taskBoardItems.compactMap(\.projectId)
      ),
      apiItemsByLane: apiItemsByLane,
      inboxItemsByLane: inboxItemsByLane,
      inboxItemsByID: inboxItemsByID,
      orderedCardIDs: orderedCardIDs(
        apiItemsByLane: apiItemsByLane,
        inboxItemsByLane: inboxItemsByLane
      ),
      decisionIDsByLane: decisionIDsByLane,
      aggregateNeedsYouCount: taskBoardNeedsYouCount
        + (inboxItemsByLane[.humanRequired]?.count ?? 0)
        + decisionIDs.count,
      aggregateOpenCount: taskBoardOpenCount
        + input.snapshot.openItemCount
        + decisionIDs.count,
      aggregateReviewCount: taskBoardReviewCount
        + reviewLanes.reduce(0) { count, lane in
          count + (inboxItemsByLane[lane]?.count ?? 0)
        },
      aggregateBlockedCount: taskBoardBlockedCount + (inboxItemsByLane[.failed]?.count ?? 0),
      aggregateDoneCount: taskBoardDoneCount + input.snapshot.completedItemCount
    )
  }

  private static let reviewLanes: Set<TaskBoardInboxLane> = [
    .agenticReview,
    .testing,
    .inReview,
    .toReview,
  ]

  private static func orderedCardIDs(
    apiItemsByLane: [TaskBoardInboxLane: [TaskBoardItem]],
    inboxItemsByLane: [TaskBoardInboxLane: [TaskBoardInboxItem]]
  ) -> [TaskBoardCardID] {
    TaskBoardInboxLane.allCases.flatMap { lane in
      (apiItemsByLane[lane] ?? []).map { .api($0.id) }
        + (inboxItemsByLane[lane] ?? []).map {
          .inbox(sessionID: $0.session.sessionId, taskID: $0.task.taskId)
        }
    }
  }

  private static func sortedTaskBoardItems(_ items: [TaskBoardItem]) -> [TaskBoardItem] {
    items
      .filter { TaskBoardInboxLane(status: $0.status) != nil && $0.deletedAt == nil }
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

  private static func sortedOpenDecisionIDs(_ decisions: [DecisionPresentationItem]) -> [String] {
    decisions
      .filter { $0.statusRaw == "open" }
      .sorted { left, right in
        let leftRank = severityRank(left.severityRaw)
        let rightRank = severityRank(right.severityRaw)
        if leftRank != rightRank {
          return leftRank > rightRank
        }
        if left.createdAt != right.createdAt {
          return left.createdAt < right.createdAt
        }
        return left.id < right.id
      }
      .map(\.id)
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

  private static func severityRank(_ severity: String) -> Int {
    switch DecisionSeverity(rawValue: severity) {
    case .critical:
      3
    case .needsUser:
      2
    case .warn:
      1
    case .info:
      0
    case .none:
      0
    }
  }
}
