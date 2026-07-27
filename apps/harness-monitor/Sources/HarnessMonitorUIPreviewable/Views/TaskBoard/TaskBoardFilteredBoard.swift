import Foundation
import HarnessMonitorKit

/// The board reduced to what the current filter leaves, plus everything the
/// filter controls need to describe themselves.
///
/// The counts and the inventory are read off the board before it is narrowed,
/// so a facet still reports what it would leave once someone switches to it.
struct TaskBoardFilteredBoard {
  let items: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisionIDs: [String]
  let doneCount: Int
  let inventory: TaskBoardFilterInventory
  /// Whether the board holds anything at all, filter aside. An empty board and
  /// a board emptied by a filter are different things to say to a person.
  let hasUnfilteredContent: Bool
  let responsibleFacets: [TaskBoardFilterFacet]

  init(
    scopedItems: [TaskBoardItem],
    visibleItems: [TaskBoardItem],
    inboxItems: [TaskBoardInboxItem],
    decisionIDs: [String],
    projectLabelResolver: TaskBoardProjectLabelResolver,
    filters: TaskBoardFilterState
  ) {
    let matcher = TaskBoardFilterMatcher(filters: filters)
    let itemFields = visibleItems.map {
      TaskBoardFilterFields(item: $0, projectLabelResolver: projectLabelResolver)
    }
    let inboxFields = inboxItems.map(TaskBoardFilterFields.init(inboxItem:))
    let population =
      itemFields
      + inboxFields
      + decisionIDs.map { _ in TaskBoardFilterFields.decision }

    inventory = TaskBoardFilterInventory(fields: population, matcher: matcher)
    hasUnfilteredContent =
      !visibleItems.isEmpty || !inboxItems.isEmpty || !decisionIDs.isEmpty

    if matcher.isEmpty {
      items = visibleItems
      self.inboxItems = inboxItems
      self.decisionIDs = decisionIDs
      doneCount = scopedItems.count { $0.deletedAt == nil && $0.status == .done }
      responsibleFacets = []
      return
    }

    items = zip(visibleItems, itemFields)
      .filter { matcher.matches($0.1) }
      .map(\.0)
    self.inboxItems = zip(inboxItems, inboxFields)
      .filter { matcher.matches($0.1) }
      .map(\.0)
    self.decisionIDs = matcher.matches(.decision) ? decisionIDs : []
    doneCount = scopedItems.count { item in
      item.deletedAt == nil
        && item.status == .done
        && matcher.matches(
          TaskBoardFilterFields(item: item, projectLabelResolver: projectLabelResolver)
        )
    }
    responsibleFacets =
      items.isEmpty && self.inboxItems.isEmpty && self.decisionIDs.isEmpty
      ? TaskBoardFilterMatcher.responsibleFacets(in: population, matcher: matcher)
      : []
  }
}
