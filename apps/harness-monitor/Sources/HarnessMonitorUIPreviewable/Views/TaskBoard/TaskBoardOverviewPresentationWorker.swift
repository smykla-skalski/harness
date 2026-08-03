import Foundation
import HarnessMonitorKit
import OSLog

struct TaskBoardOverviewPresentationInput: Equatable, Sendable {
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let decisionItems: [DecisionPresentationItem]
  let scopeSessionID: String?
  let configuredRepositories: [String]?
  let taskBoardItemsSnapshotAvailable: Bool
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let latestEvaluation: TaskBoardEvaluationSummary?
  let latestEvaluationBaselineRunID: String?
  let localHostProjectTypes: [String]?
  /// The registered project catalog every card resolves its name through.
  let taskBoardProjects: [TaskBoardProjectSummary]
  let filters: TaskBoardFilterState
  /// Text as the field holds it, once the keystrokes have settled.
  let searchText: String

  /// Spelled out so `filters` and `searchText` can default without giving up
  /// `let`: a value this snapshot hands to an actor should not be mutable after
  /// the fact.
  init(
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem],
    decisionItems: [DecisionPresentationItem],
    scopeSessionID: String?,
    configuredRepositories: [String]? = nil,
    taskBoardItemsSnapshotAvailable: Bool = true,
    orchestratorStatus: TaskBoardOrchestratorStatus? = nil,
    latestEvaluation: TaskBoardEvaluationSummary? = nil,
    latestEvaluationBaselineRunID: String? = nil,
    localHostProjectTypes: [String]? = nil,
    taskBoardProjects: [TaskBoardProjectSummary],
    filters: TaskBoardFilterState = TaskBoardFilterState(),
    searchText: String = ""
  ) {
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.decisionItems = decisionItems
    self.scopeSessionID = scopeSessionID
    self.configuredRepositories = configuredRepositories
    self.taskBoardItemsSnapshotAvailable = taskBoardItemsSnapshotAvailable
    self.orchestratorStatus = orchestratorStatus
    self.latestEvaluation = latestEvaluation
    self.latestEvaluationBaselineRunID = latestEvaluationBaselineRunID
    self.localHostProjectTypes = localHostProjectTypes
    self.taskBoardProjects = taskBoardProjects
    self.filters = filters
    self.searchText = searchText
  }
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
    apiCardPresentationsByLane: [:],
    inboxCardPresentationsByLane: [:],
    decisionIDsByLane: [:],
    orchestratorPresentation: nil,
    aggregateNeedsYouCount: 0,
    aggregateOpenCount: 0,
    aggregateReviewCount: 0,
    aggregateBlockedCount: 0,
    aggregateDoneCount: 0,
    filterInventory: .empty,
    searchCandidates: [],
    hasUnfilteredContent: false,
    responsibleNarrowingCauses: []
  )

  let taskBoardItems: [TaskBoardItem]
  let taskBoardItemsByID: [String: TaskBoardItem]
  let projectLabelResolver: TaskBoardProjectLabelResolver
  let apiItemsByLane: [TaskBoardInboxLane: [TaskBoardItem]]
  let inboxItemsByLane: [TaskBoardInboxLane: [TaskBoardInboxItem]]
  let inboxItemsByID: [TaskBoardCardID: TaskBoardInboxItem]
  let orderedCardIDs: [TaskBoardCardID]
  let apiCardPresentationsByLane: [TaskBoardInboxLane: [String: TaskBoardCardPresentation]]
  let inboxCardPresentationsByLane:
    [TaskBoardInboxLane: [TaskBoardCardID: TaskBoardCardPresentation]]
  let decisionIDsByLane: [TaskBoardInboxLane: [String]]
  private(set) var orchestratorPresentation: TaskBoardOrchestratorPresentation?
  let aggregateNeedsYouCount: Int
  let aggregateOpenCount: Int
  let aggregateReviewCount: Int
  let aggregateBlockedCount: Int
  let aggregateDoneCount: Int
  let filterInventory: TaskBoardFilterInventory
  /// What the search field suggests from: the cards the facets leave, before
  /// the search narrows them.
  let searchCandidates: [TaskBoardSearchCandidate]
  /// Whether the board holds anything at all, filter and search aside.
  let hasUnfilteredContent: Bool
  /// Populated only when the filter or the search is what left the board empty.
  let responsibleNarrowingCauses: [TaskBoardNarrowingCause]

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

  /// The item Step Mode targets: the next candidate the automated orchestrator
  /// would act on, i.e. the top of the Todo lane. Step Mode exists to observe the
  /// automated process one stage at a time, so the target is derived purely from
  /// board state and never from the user's card selection.
  var stepRailTargetItem: TaskBoardItem? {
    apiItems(in: .todo).first
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

  func apiCardPresentations(in lane: TaskBoardInboxLane) -> [String: TaskBoardCardPresentation] {
    apiCardPresentationsByLane[lane] ?? [:]
  }

  func inboxCardPresentations(
    in lane: TaskBoardInboxLane
  ) -> [TaskBoardCardID: TaskBoardCardPresentation] {
    inboxCardPresentationsByLane[lane] ?? [:]
  }

  func replacingOrchestratorPresentation(
    _ presentation: TaskBoardOrchestratorPresentation?
  ) -> Self {
    var copy = self
    copy.orchestratorPresentation = presentation
    return copy
  }

  /// Projects the store's synchronous optimistic move into the rendered lane
  /// arrays. The full presentation worker still reconciles the authoritative
  /// snapshot off-main; this path only avoids waiting for that second hop
  /// before settling the dropped card.
  func replacingTaskBoardItemsForImmediatePosition(
    _ items: [TaskBoardItem],
    scopeSessionID: String?
  ) -> Self {
    let scopedItems =
      if let scopeSessionID {
        items.filter { $0.sessionId == scopeSessionID }
      } else {
        items
      }
    // A position mutation cannot change any facet or search field. Keep the
    // exact membership the worker already resolved, while taking status and
    // ordering from the store's synchronous optimistic snapshot.
    let presentedItemIDs = Set(taskBoardItemsByID.keys)
    let visibleItems = TaskBoardVisibleItems.visibleItemsPreservingOrder(scopedItems)
      .filter { presentedItemIDs.contains($0.id) }
    let nextItemsByLane = Dictionary(grouping: visibleItems) { item in
      TaskBoardInboxLane(taskBoardItem: item) ?? .inbox
    }
    let presentationsByID = apiCardPresentationsByLane.values.reduce(
      into: [String: TaskBoardCardPresentation]()
    ) { result, lanePresentations in
      result.merge(lanePresentations, uniquingKeysWith: { current, _ in current })
    }
    let nextCardPresentationsByLane = nextItemsByLane.mapValues { laneItems in
      Dictionary(
        uniqueKeysWithValues: laneItems.compactMap { item in
          presentationsByID[item.id].map { (item.id, $0) }
        }
      )
    }
    let reviewLanes: Set<TaskBoardInboxLane> = [
      .agenticReview,
      .testing,
      .inReview,
      .toReview,
    ]
    let priorNeedsYouCount = apiItemsByLane[.humanRequired]?.count ?? 0
    let nextNeedsYouCount = nextItemsByLane[.humanRequired]?.count ?? 0
    let priorReviewCount = reviewLanes.reduce(0) { count, lane in
      count + (apiItemsByLane[lane]?.count ?? 0)
    }
    let nextReviewCount = reviewLanes.reduce(0) { count, lane in
      count + (nextItemsByLane[lane]?.count ?? 0)
    }
    let priorBlockedCount = apiItemsByLane[.failed]?.count ?? 0
    let nextBlockedCount = nextItemsByLane[.failed]?.count ?? 0
    let priorOpenCount = taskBoardItems.count { $0.status != .done }
    let nextOpenCount = visibleItems.count { $0.status != .done }

    return Self(
      taskBoardItems: visibleItems,
      taskBoardItemsByID: Dictionary(
        uniqueKeysWithValues: visibleItems.map { ($0.id, $0) }
      ),
      projectLabelResolver: projectLabelResolver,
      apiItemsByLane: nextItemsByLane,
      inboxItemsByLane: inboxItemsByLane,
      inboxItemsByID: inboxItemsByID,
      orderedCardIDs: TaskBoardInboxLane.allCases.flatMap { lane in
        (nextItemsByLane[lane] ?? []).map { .api($0.id) }
          + (inboxItemsByLane[lane] ?? []).map {
            .inbox(
              sessionID: $0.session.sessionId,
              taskID: $0.task.taskId
            )
          }
      },
      apiCardPresentationsByLane: nextCardPresentationsByLane,
      inboxCardPresentationsByLane: inboxCardPresentationsByLane,
      decisionIDsByLane: decisionIDsByLane,
      orchestratorPresentation: orchestratorPresentation,
      aggregateNeedsYouCount: aggregateNeedsYouCount - priorNeedsYouCount
        + nextNeedsYouCount,
      aggregateOpenCount: aggregateOpenCount - priorOpenCount + nextOpenCount,
      aggregateReviewCount: aggregateReviewCount - priorReviewCount + nextReviewCount,
      aggregateBlockedCount: aggregateBlockedCount - priorBlockedCount + nextBlockedCount,
      aggregateDoneCount: aggregateDoneCount,
      filterInventory: filterInventory,
      searchCandidates: searchCandidates,
      hasUnfilteredContent: hasUnfilteredContent,
      responsibleNarrowingCauses: responsibleNarrowingCauses
    )
  }
}
