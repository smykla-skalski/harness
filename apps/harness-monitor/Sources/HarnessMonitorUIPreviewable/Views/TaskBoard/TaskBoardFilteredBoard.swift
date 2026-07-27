import Foundation
import HarnessMonitorKit

/// The board reduced to what the current filter and search leave, plus
/// everything the controls above it need to describe themselves.
///
/// The counts and the inventory are read off the board before it is narrowed,
/// so a facet still reports what it would leave once someone switches to it.
struct TaskBoardFilteredBoard {
  let items: [TaskBoardItem]
  let inboxItems: [TaskBoardInboxItem]
  let decisionIDs: [String]
  let doneCount: Int
  let inventory: TaskBoardFilterInventory
  /// What the suggestions under the search field are drawn from: the cards the
  /// facets leave, before the search narrows them. Suggesting a card the active
  /// filter hides would complete into an empty board.
  let searchCandidates: [TaskBoardSearchCandidate]
  /// Whether the board holds anything at all, filter and search aside. An empty
  /// board and a board emptied by a filter are different things to say to a
  /// person.
  let hasUnfilteredContent: Bool
  let responsibleCauses: [TaskBoardNarrowingCause]

  init(
    scopedItems: [TaskBoardItem],
    visibleItems: [TaskBoardItem],
    inboxItems: [TaskBoardInboxItem],
    decisions: [DecisionPresentationItem],
    projectLabelResolver: TaskBoardProjectLabelResolver,
    filters: TaskBoardFilterState,
    search: TaskBoardSearchQuery = .none
  ) {
    let matcher = TaskBoardFilterMatcher(filters: filters, search: search)
    // Folded up front, and only when there is a search, because everything
    // below asks each card whether it matches several times over.
    let prepare = Self.searchPreparation(for: search)
    let itemFields = visibleItems.map {
      prepare(TaskBoardFilterFields(item: $0, projectLabelResolver: projectLabelResolver))
    }
    let inboxFields = inboxItems.map { prepare(TaskBoardFilterFields(inboxItem: $0)) }
    let decisionFields = decisions.map { prepare(TaskBoardFilterFields(decision: $0)) }
    let population = itemFields + inboxFields + decisionFields

    inventory = TaskBoardFilterInventory(fields: population, matcher: matcher)
    searchCandidates = Self.searchCandidates(
      items: zip(visibleItems, itemFields),
      inboxItems: zip(inboxItems, inboxFields),
      decisions: zip(decisions, decisionFields),
      matcher: matcher
    )
    hasUnfilteredContent =
      !visibleItems.isEmpty || !inboxItems.isEmpty || !decisions.isEmpty

    if matcher.isEmpty {
      items = visibleItems
      self.inboxItems = inboxItems
      decisionIDs = decisions.map(\.id)
      doneCount = scopedItems.count { $0.deletedAt == nil && $0.status == .done }
      responsibleCauses = []
      return
    }

    items = zip(visibleItems, itemFields)
      .filter { matcher.matches($0.1) }
      .map(\.0)
    self.inboxItems = zip(inboxItems, inboxFields)
      .filter { matcher.matches($0.1) }
      .map(\.0)
    decisionIDs = zip(decisions, decisionFields)
      .filter { matcher.matches($0.1) }
      .map(\.0.id)
    doneCount = scopedItems.count { item in
      item.deletedAt == nil
        && item.status == .done
        && matcher.matches(
          prepare(TaskBoardFilterFields(item: item, projectLabelResolver: projectLabelResolver))
        )
    }
    responsibleCauses =
      items.isEmpty && self.inboxItems.isEmpty && decisionIDs.isEmpty
      ? TaskBoardFilterMatcher.responsibleCauses(in: population, matcher: matcher)
      : []
  }

  /// Folding costs nothing to skip and is the expensive half of matching, so a
  /// board nobody is searching never pays for it.
  private static func searchPreparation(
    for search: TaskBoardSearchQuery
  ) -> (TaskBoardFilterFields) -> TaskBoardFilterFields {
    guard !search.isEmpty else {
      return { $0 }
    }
    return { fields in
      var prepared = fields
      prepared.prepareForSearch()
      return prepared
    }
  }

  private static func searchCandidates(
    items: Zip2Sequence<[TaskBoardItem], [TaskBoardFilterFields]>,
    inboxItems: Zip2Sequence<[TaskBoardInboxItem], [TaskBoardFilterFields]>,
    decisions: Zip2Sequence<[DecisionPresentationItem], [TaskBoardFilterFields]>,
    matcher: TaskBoardFilterMatcher
  ) -> [TaskBoardSearchCandidate] {
    func survivesFacets(_ fields: TaskBoardFilterFields) -> Bool {
      matcher.matches(fields, excluding: .search)
    }

    return items.compactMap { item, fields in
      guard survivesFacets(fields) else { return nil }
      return TaskBoardSearchCandidate(
        id: item.id,
        title: item.title,
        subtitle: fields.projectLabel ?? "",
        tags: item.tags
      )
    }
      + inboxItems.compactMap { inboxItem, fields in
        guard survivesFacets(fields) else { return nil }
        return TaskBoardSearchCandidate(
          id: inboxItem.id,
          title: inboxItem.task.title,
          subtitle: inboxItem.subtitle,
          tags: []
        )
      }
      + decisions.compactMap { decision, fields in
        guard survivesFacets(fields) else { return nil }
        return TaskBoardSearchCandidate(
          id: decision.id,
          title: decision.summary,
          subtitle: "Decision",
          tags: []
        )
      }
  }
}
