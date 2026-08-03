import Foundation
import HarnessMonitorKit
import OSLog

actor TaskBoardOverviewPresentationWorker {
  private struct BoardInput: Equatable {
    let snapshot: TaskBoardInboxSnapshot
    let taskBoardItems: [TaskBoardItem]
    let decisionItems: [DecisionPresentationItem]
    let scopeSessionID: String?
    let configuredRepositories: [String]?
    let taskBoardProjects: [TaskBoardProjectSummary]
    let filters: TaskBoardFilterState
    let searchText: String

    init(_ input: TaskBoardOverviewPresentationInput) {
      snapshot = input.snapshot
      taskBoardItems = input.taskBoardItems
      decisionItems = input.decisionItems
      scopeSessionID = input.scopeSessionID
      configuredRepositories = input.configuredRepositories
      taskBoardProjects = input.taskBoardProjects
      filters = input.filters
      searchText = input.searchText
    }
  }

  private struct BoardPresentationResolution {
    let presentation: TaskBoardOverviewPresentation
    let repositoryScopedItems: [TaskBoardItem]
  }

  private struct FilteredBoardResolution {
    let board: TaskBoardFilteredBoard
    let projectLabelResolver: TaskBoardProjectLabelResolver
    let repositoryScopedItems: [TaskBoardItem]
  }

  private static let signposter = OSSignposter(
    subsystem: "io.harnessmonitor",
    category: "perf"
  )

  private var cachedInput: TaskBoardOverviewPresentationInput?
  private var cachedOutput = TaskBoardOverviewPresentation.empty
  private var cachedBoardInput: BoardInput?
  private var cachedBoardPresentation = TaskBoardOverviewPresentation.empty
  private var cachedRepositoryScopedItems: [TaskBoardItem] = []
  private var boardRebuildCount: UInt64 = 0

  func compute(input: TaskBoardOverviewPresentationInput) -> TaskBoardOverviewPresentation {
    guard input != cachedInput else {
      return cachedOutput
    }

    let boardInput = BoardInput(input)
    if boardInput != cachedBoardInput {
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
      let resolution = Self.presentation(from: input)
      cachedBoardInput = boardInput
      cachedBoardPresentation = resolution.presentation
      cachedRepositoryScopedItems = resolution.repositoryScopedItems
      boardRebuildCount &+= 1
      Self.signposter.endInterval(
        "task_board_overview.presentation.compute",
        interval,
        "api_visible=\(resolution.presentation.taskBoardItems.count, privacy: .public)"
      )
    }

    cachedInput = input
    let orchestratorPresentation = input.orchestratorStatus.map { status in
      TaskBoardOrchestratorPresentation(
        status: status,
        taskBoardItems: cachedRepositoryScopedItems,
        localHostProjectTypes: input.localHostProjectTypes,
        latestEvaluation: input.latestEvaluation,
        latestEvaluationBaselineRunID: input.latestEvaluationBaselineRunID,
        repositoryScopeIsKnown: input.configuredRepositories != nil
          && input.taskBoardItemsSnapshotAvailable
      )
    }
    cachedOutput = cachedBoardPresentation.replacingOrchestratorPresentation(
      orchestratorPresentation
    )
    return cachedOutput
  }

  func waitForIdle() async {}

  func boardRebuildCountForTesting() -> UInt64 {
    boardRebuildCount
  }

  private static func presentation(
    from input: TaskBoardOverviewPresentationInput
  ) -> BoardPresentationResolution {
    let resolution = filteredBoard(from: input)
    let filtered = resolution.board
    let projectLabelResolver = resolution.projectLabelResolver
    let repositoryScopedItems = resolution.repositoryScopedItems
    let taskBoardItems = filtered.items
    let apiItemsByLane = Dictionary(grouping: taskBoardItems) { item in
      TaskBoardInboxLane(taskBoardItem: item) ?? .inbox
    }
    let inboxItems = filtered.inboxItems
    let inboxItemsByLane = Dictionary(grouping: inboxItems, by: \.lane)
    let inboxItemsByID = Dictionary(
      inboxItems.map { item in
        (inboxCardID(for: item), item)
      },
      uniquingKeysWith: { first, _ in first }
    )
    let decisionIDs = filtered.decisionIDs
    let decisionIDsByLane: [TaskBoardInboxLane: [String]] =
      decisionIDs.isEmpty ? [:] : [.humanRequired: decisionIDs]

    let taskBoardNeedsYouCount = apiItemsByLane[.humanRequired]?.count ?? 0
    let taskBoardReviewCount = reviewLanes.reduce(0) { count, lane in
      count + (apiItemsByLane[lane]?.count ?? 0)
    }
    let taskBoardBlockedCount = apiItemsByLane[.failed]?.count ?? 0
    let taskBoardDoneCount = filtered.doneCount
    // A closed umbrella stays visible in its own lane (unlike an ordinary closed
    // item, which drops off the board entirely), so it is in `taskBoardItems` -
    // exclude it here or it would double-count as both open and done.
    let taskBoardOpenCount = taskBoardItems.count { $0.status != .done }
    // One parser (and its 3 formatters) for the whole snapshot, not one per card.
    let dateParser = TaskBoardCardDateParser()

    let presentation = TaskBoardOverviewPresentation(
      taskBoardItems: taskBoardItems,
      taskBoardItemsByID: Dictionary(uniqueKeysWithValues: taskBoardItems.map { ($0.id, $0) }),
      projectLabelResolver: projectLabelResolver,
      apiItemsByLane: apiItemsByLane,
      inboxItemsByLane: inboxItemsByLane,
      inboxItemsByID: inboxItemsByID,
      orderedCardIDs: orderedCardIDs(
        apiItemsByLane: apiItemsByLane,
        inboxItemsByLane: inboxItemsByLane
      ),
      apiCardPresentationsByLane: apiItemsByLane.mapValues { items in
        Dictionary(
          uniqueKeysWithValues: items.map {
            (
              $0.id,
              TaskBoardCardPresentation.forAPIItem(
                $0,
                projectLabelResolver: projectLabelResolver,
                dateParser: dateParser
              )
            )
          }
        )
      },
      inboxCardPresentationsByLane: inboxItemsByLane.mapValues { items in
        Dictionary(
          uniqueKeysWithValues: items.map {
            (
              inboxCardID(for: $0),
              TaskBoardCardPresentation.forInboxItem($0, dateParser: dateParser)
            )
          }
        )
      },
      decisionIDsByLane: decisionIDsByLane,
      orchestratorPresentation: nil,
      aggregateNeedsYouCount: taskBoardNeedsYouCount
        + (inboxItemsByLane[.humanRequired]?.count ?? 0)
        + decisionIDs.count,
      aggregateOpenCount: taskBoardOpenCount
        + inboxItems.count
        + decisionIDs.count,
      aggregateReviewCount: taskBoardReviewCount
        + reviewLanes.reduce(0) { count, lane in
          count + (inboxItemsByLane[lane]?.count ?? 0)
        },
      aggregateBlockedCount: taskBoardBlockedCount + (inboxItemsByLane[.failed]?.count ?? 0),
      aggregateDoneCount: taskBoardDoneCount + input.snapshot.completedItemCount,
      filterInventory: filtered.inventory,
      searchCandidates: filtered.searchCandidates,
      hasUnfilteredContent: filtered.hasUnfilteredContent,
      responsibleNarrowingCauses: filtered.responsibleCauses
    )
    return BoardPresentationResolution(
      presentation: presentation,
      repositoryScopedItems: repositoryScopedItems
    )
  }

  private static func filteredBoard(
    from input: TaskBoardOverviewPresentationInput
  ) -> FilteredBoardResolution {
    let scopedTaskBoardItems =
      if let scopeSessionID = input.scopeSessionID {
        input.taskBoardItems.filter { $0.sessionId == scopeSessionID }
      } else {
        input.taskBoardItems
      }
    let repositoryScopedItems = TaskBoardConfiguredRepositoryScope(
      repositories: input.configuredRepositories,
      projects: input.taskBoardProjects
    ).filter(scopedTaskBoardItems)
    let visibleItems = TaskBoardVisibleItems.visibleItemsPreservingOrder(repositoryScopedItems)
    // Resolved before the filter narrows anything: which repository names are
    // ambiguous is a property of the whole board, not of the current view of it.
    let projectLabelResolver = TaskBoardProjectLabelResolver(
      projects: input.taskBoardProjects,
      projectIDs: visibleItems.compactMap(\.taskBoardRepositoryIdentity)
    )
    let filtered = TaskBoardFilteredBoard(
      scopedItems: repositoryScopedItems,
      visibleItems: visibleItems,
      inboxItems: uniqueInboxItems(input.snapshot.items),
      decisions: sortedOpenDecisions(input.decisionItems),
      projectLabelResolver: projectLabelResolver,
      filters: input.filters,
      search: TaskBoardSearchQuery(input.searchText)
    )
    return FilteredBoardResolution(
      board: filtered,
      projectLabelResolver: projectLabelResolver,
      repositoryScopedItems: repositoryScopedItems
    )
  }

  private static let reviewLanes: Set<TaskBoardInboxLane> = [
    .agenticReview,
    .testing,
    .inReview,
    .toReview,
  ]

  private static func uniqueInboxItems(
    _ items: [TaskBoardInboxItem]
  ) -> [TaskBoardInboxItem] {
    var seenIDs: Set<TaskBoardCardID> = []
    return items.filter { seenIDs.insert(inboxCardID(for: $0)).inserted }
  }

  private static func inboxCardID(for item: TaskBoardInboxItem) -> TaskBoardCardID {
    .inbox(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
  }

  private static func orderedCardIDs(
    apiItemsByLane: [TaskBoardInboxLane: [TaskBoardItem]],
    inboxItemsByLane: [TaskBoardInboxLane: [TaskBoardInboxItem]]
  ) -> [TaskBoardCardID] {
    TaskBoardInboxLane.allCases.flatMap { lane in
      (apiItemsByLane[lane] ?? []).map { .api($0.id) }
        + (inboxItemsByLane[lane] ?? []).map {
          inboxCardID(for: $0)
        }
    }
  }

  private static func sortedOpenDecisions(
    _ decisions: [DecisionPresentationItem]
  ) -> [DecisionPresentationItem] {
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
