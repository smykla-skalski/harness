import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board text search")
struct TaskBoardSearchTests {
  @Test("Search reads title, body, and tags")
  func searchReadsTitleBodyAndTags() {
    let card = fields(
      title: "Retry zone sync",
      body: "The zone loses its lease on a partial failure",
      tags: ["backend"]
    )

    #expect(TaskBoardSearchQuery("retry").matches(card))
    #expect(TaskBoardSearchQuery("lease").matches(card))
    #expect(TaskBoardSearchQuery("backend").matches(card))
    #expect(!TaskBoardSearchQuery("frontend").matches(card))
  }

  @Test("Matching is literal, so the result is explainable from what was typed")
  func matchingIsLiteral() {
    let card = fields(title: "Retry zone sync on partial failure")

    #expect(TaskBoardSearchQuery("zone sync").matches(card))
    // A typo is the suggestions' problem, not the board's.
    #expect(!TaskBoardSearchQuery("zonr").matches(card))
  }

  @Test("Case and accents are ignored")
  func caseAndAccentsAreIgnored() {
    let card = fields(title: "Naïve RETRY path")

    #expect(TaskBoardSearchQuery("naive").matches(card))
    #expect(TaskBoardSearchQuery("retry").matches(card))
  }

  @Test("Every term has to appear, so a second word narrows further")
  func everyTermHasToAppear() {
    let card = fields(title: "Retry zone sync", body: "Runs on the mesh")

    #expect(TaskBoardSearchQuery("retry mesh").matches(card))
    #expect(!TaskBoardSearchQuery("retry ingress").matches(card))
  }

  @Test("No term matches across the seam between two fields")
  func termsDoNotMatchAcrossFields() {
    let card = fields(title: "sync", body: "zone")

    #expect(!TaskBoardSearchQuery("syncz").matches(card))
  }

  @Test("Whitespace alone is not a search")
  func whitespaceAloneIsNotASearch() {
    #expect(TaskBoardSearchQuery("   ").isEmpty)
    #expect(TaskBoardSearchQuery("   ").matches(fields(title: "anything")))
    #expect(TaskBoardFilterMatcher(filters: TaskBoardFilterState(), search: .none).isEmpty)
  }

  @Test("Search and field filters narrow together rather than replacing one another")
  func searchAndFiltersNarrowTogether() {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)
    let matcher = TaskBoardFilterMatcher(
      filters: filters,
      search: TaskBoardSearchQuery("zone")
    )

    #expect(matcher.matches(fields(title: "Retry zone sync", priority: .critical)))
    #expect(!matcher.matches(fields(title: "Retry zone sync", priority: .low)))
    #expect(!matcher.matches(fields(title: "Split the reconciler", priority: .critical)))
  }

  @Test("An empty board names the search when the search is what emptied it")
  func emptyBoardNamesTheSearch() {
    let matcher = TaskBoardFilterMatcher(
      filters: TaskBoardFilterState(),
      search: TaskBoardSearchQuery("ingress")
    )
    let population = [fields(title: "Retry zone sync")]

    #expect(
      TaskBoardFilterMatcher.responsibleCauses(in: population, matcher: matcher) == [.search]
    )
    #expect(
      TaskBoardFilterEmptyState.description(responsibleCauses: [.search])
        == "Nothing on the board matches the search."
    )
    #expect(TaskBoardFilterEmptyState.clearTitle(responsibleCauses: [.search]) == "Clear Search")
  }

  @Test("An empty board names the search and the filter when only the pair empties it")
  func emptyBoardNamesSearchAndFilterTogether() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("harness")
    let matcher = TaskBoardFilterMatcher(
      filters: filters,
      search: TaskBoardSearchQuery("zone")
    )
    let population = [
      fields(title: "Retry zone sync", projectKey: "kuma"),
      fields(title: "Pairing panel drops the device", projectKey: "harness"),
    ]

    let causes = TaskBoardFilterMatcher.responsibleCauses(in: population, matcher: matcher)

    #expect(causes == [.search, .facet(.project)])
    #expect(
      TaskBoardFilterEmptyState.description(responsibleCauses: causes)
        == "Nothing on the board matches the search and the project filter together."
    )
    #expect(
      TaskBoardFilterEmptyState.clearTitle(responsibleCauses: causes)
        == "Clear Search and Filters"
    )
  }

  @Test("Facet counts keep applying the search")
  func facetCountsKeepApplyingTheSearch() {
    let matcher = TaskBoardFilterMatcher(
      filters: TaskBoardFilterState(),
      search: TaskBoardSearchQuery("zone")
    )
    let inventory = TaskBoardFilterInventory(
      fields: [
        fields(title: "Retry zone sync", priority: .high, projectKey: "kuma"),
        fields(title: "Split the reconciler", priority: .high, projectKey: "kuma"),
      ],
      matcher: matcher
    )

    // Both cards are listed under the project they carry, but only the one the
    // search leaves is counted.
    #expect(inventory.projects.map(\.id) == ["kuma"])
    #expect(inventory.projects.map(\.count) == [1])
  }

  @Test("Suggestions come from the cards the filters leave, and tolerate a typo")
  func suggestionsComeFromTheFilteredBoardAndTolerateATypo() async {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kuma")
    let board = board(
      items: [
        item(id: "zone-sync", title: "Retry zone sync on partial failure", projectID: "kuma"),
        item(id: "pairing", title: "Pairing panel drops the device", projectID: "harness"),
      ],
      filters: filters
    )

    #expect(board.searchCandidates.map(\.id) == ["zone-sync"])

    let suggestions = await TaskBoardSearchSuggestionWorker()
      .suggestions(query: "zonr", candidates: board.searchCandidates)

    #expect(suggestions.map(\.id) == ["zone-sync"])
  }

  @Test("Clearing the text restores the board the field filters left")
  func clearingTheTextRestoresTheFilteredBoard() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kuma")
    let items = [
      item(id: "zone-sync", title: "Retry zone sync", projectID: "kuma"),
      item(id: "reconciler", title: "Split the reconciler", projectID: "kuma"),
      item(id: "pairing", title: "Pairing panel drops the device", projectID: "harness"),
    ]

    let searched = board(items: items, filters: filters, search: "zone")
    let cleared = board(items: items, filters: filters, search: "")

    #expect(searched.items.map(\.id) == ["zone-sync"])
    #expect(cleared.items.map(\.id) == ["zone-sync", "reconciler"])
  }

  private func board(
    items: [TaskBoardItem],
    filters: TaskBoardFilterState,
    search: String = ""
  ) -> TaskBoardFilteredBoard {
    TaskBoardFilteredBoard(
      scopedItems: items,
      visibleItems: items,
      inboxItems: [],
      decisions: [],
      projectLabelResolver: TaskBoardProjectLabelResolver(
        projectIDs: items.compactMap(\.taskBoardRepositoryIdentity)
      ),
      filters: filters,
      search: TaskBoardSearchQuery(search)
    )
  }

  private func item(id: String, title: String, projectID: String) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: title,
      body: "",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: projectID,
      sourceProjectId: projectID,
      agentMode: .headless,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-27T09:00:00Z",
      updatedAt: "2026-07-27T10:00:00Z",
      deletedAt: nil
    )
  }

  private func fields(
    title: String = "",
    body: String = "",
    priority: TaskBoardPriority? = nil,
    projectKey: String? = nil,
    tags: [String] = []
  ) -> TaskBoardFilterFields {
    TaskBoardFilterFields(
      title: title,
      body: body,
      priority: priority,
      projectKey: projectKey,
      projectLabel: projectKey,
      tags: tags
    )
  }
}
