import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board field filters")
struct TaskBoardFilterTests {
  @Test("Facets narrow together while values inside one facet widen it")
  func facetsNarrowTogetherWhileValuesWiden() {
    let criticalBackend = fields(priority: .critical, tags: ["backend"])
    let lowBackend = fields(priority: .low, tags: ["backend"])
    let criticalUI = fields(priority: .critical, tags: ["ui"])

    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)
    filters.togglePriority(.low)
    let widened = TaskBoardFilterMatcher(filters: filters)

    #expect(widened.matches(criticalBackend))
    #expect(widened.matches(lowBackend))
    #expect(widened.matches(criticalUI))

    filters.toggleTag("backend")
    let narrowed = TaskBoardFilterMatcher(filters: filters)

    #expect(narrowed.matches(criticalBackend))
    #expect(narrowed.matches(lowBackend))
    #expect(!narrowed.matches(criticalUI))
  }

  @Test("A card without the filtered field never matches it")
  func cardWithoutFilteredFieldNeverMatches() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kumahq/kuma")
    let matcher = TaskBoardFilterMatcher(filters: filters)

    #expect(matcher.matches(fields(projectKey: "kumahq/kuma")))
    #expect(!matcher.matches(fields(priority: .low)))
    // An open decision carries no facet at all.
    #expect(!matcher.matches(TaskBoardFilterFields()))
  }

  @Test("Status is not a facet: the lanes already are the statuses")
  func statusIsNotAFacet() {
    #expect(TaskBoardFilterFacet.allCases.map(\.rawValue) == ["project", "priority", "tag", "source"])
    #expect(TaskBoardFilterFacet.dedicated == [.project, .priority])
    #expect(TaskBoardFilterFacet.general == [.tag, .source])
  }

  @Test("Tag matching ignores case and surrounding whitespace")
  func tagMatchingIgnoresCaseAndWhitespace() {
    var filters = TaskBoardFilterState()
    filters.toggleTag(" Backend ")
    let matcher = TaskBoardFilterMatcher(filters: filters)

    #expect(matcher.matches(fields(tags: ["backend"])))
    #expect(matcher.matches(fields(tags: ["BACKEND "])))
    #expect(!matcher.matches(fields(tags: ["backends"])))
  }

  @Test("Every count reports what the facet would leave, ignoring its own selection")
  func countsIgnoreTheFacetTheyBelongTo() {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.high)
    let inventory = TaskBoardFilterInventory(
      fields: [
        fields(priority: .high, projectKey: "kuma"),
        fields(priority: .low, projectKey: "kuma"),
        fields(priority: .high, projectKey: "harness"),
      ],
      matcher: TaskBoardFilterMatcher(filters: filters)
    )

    // Project counts respect the active priority filter.
    #expect(inventory.projects.map(\.id) == ["harness", "kuma"])
    #expect(inventory.projects.map(\.count) == [1, 1])
    // Priority counts ignore the priority filter, so `low` still reports its own reach.
    #expect(inventory.priorities.map(\.id) == ["high", "low"])
    #expect(inventory.priorities.first { $0.id == "low" }?.count == 1)
  }

  @Test("A selected value stays listed once nothing carries it any more")
  func selectedValueStaysListedWithoutMatches() {
    var filters = TaskBoardFilterState()
    filters.toggleTag("retired")
    let inventory = TaskBoardFilterInventory(
      fields: [fields(tags: ["backend"])],
      matcher: TaskBoardFilterMatcher(filters: filters)
    )

    #expect(inventory.tags.map(\.id) == ["backend", "retired"])
    #expect(inventory.tags.first { $0.id == "retired" }?.count == 0)
  }

  @Test("An empty result names the one filter that caused it")
  func emptyResultNamesTheResponsibleFilter() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kuma")
    filters.togglePriority(.critical)
    let matcher = TaskBoardFilterMatcher(filters: filters)
    let population = [fields(priority: .low, projectKey: "kuma")]

    #expect(!population.contains { matcher.matches($0) })
    #expect(
      TaskBoardFilterMatcher.responsibleCauses(in: population, matcher: matcher)
        == [.facet(.priority)]
    )
  }

  @Test("An empty result blames every active filter when no single one is at fault")
  func emptyResultBlamesEveryFilterWhenNoSingleOneIsAtFault() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kuma")
    filters.togglePriority(.critical)
    let matcher = TaskBoardFilterMatcher(filters: filters)
    let population = [fields(priority: .low, projectKey: "harness")]

    #expect(
      TaskBoardFilterMatcher.responsibleCauses(in: population, matcher: matcher)
        == [.facet(.project), .facet(.priority)]
    )
  }

  @Test("Clearing one facet leaves the rest of the filter alone")
  func clearingOneFacetLeavesTheRestAlone() {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.high)
    filters.toggleTag("backend")
    filters.toggleSource(.gitHub)

    filters.clear(.tag)

    #expect(filters.tags.isEmpty)
    #expect(filters.priorities == [.high])
    #expect(filters.sources == [.gitHub])
    #expect(filters.activeFacets == [.priority, .source])

    filters.clear()

    #expect(filters.isEmpty)
  }

  @Test("The general control counts only the values it owns")
  func generalControlCountsOnlyItsOwnValues() {
    var filters = TaskBoardFilterState()
    filters.toggleProject("kuma")
    filters.togglePriority(.high)
    filters.toggleTag("backend")
    filters.toggleSource(.gitHub)

    #expect(filters.activeValueCount == 4)
    #expect(filters.activeValueCount(in: TaskBoardFilterFacet.general) == 2)
    #expect(filters.activeValueCount(in: TaskBoardFilterFacet.dedicated) == 2)
  }

  @Test("A stored filter survives a round trip through its raw value")
  func storedFilterSurvivesRoundTrip() {
    var filters = TaskBoardFilterState()
    filters.togglePriority(.critical)
    filters.toggleProject("kumahq/kuma")
    filters.toggleTag("Backend")
    filters.toggleSource(.gitHub)

    let rawValue = TaskBoardFilterPreferences.rawValue(for: filters)

    #expect(TaskBoardFilterPreferences.state(from: rawValue) == filters)
    #expect(TaskBoardFilterPreferences.state(from: "").isEmpty)
    #expect(TaskBoardFilterPreferences.state(from: "not json").isEmpty)
  }

  @Test("An empty filter stores nothing rather than an empty envelope")
  func emptyFilterStoresNothing() {
    #expect(
      TaskBoardFilterPreferences.rawValue(for: TaskBoardFilterState())
        == TaskBoardFilterPreferences.emptyRawValue
    )
  }

  private func fields(
    priority: TaskBoardPriority? = nil,
    projectKey: String? = nil,
    tags: [String] = [],
    source: TaskBoardFilterSource? = nil
  ) -> TaskBoardFilterFields {
    TaskBoardFilterFields(
      priority: priority,
      projectKey: projectKey,
      projectLabel: projectKey,
      tags: tags,
      source: source
    )
  }
}
