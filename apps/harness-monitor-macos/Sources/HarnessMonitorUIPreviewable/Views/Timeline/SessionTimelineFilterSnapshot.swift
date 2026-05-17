import Foundation
import HarnessMonitorKit

struct SessionTimelineFacetOption: Identifiable, Equatable, Sendable {
  let id: String
  let label: String
  let count: Int
}

struct SessionTimelineFilterInventory: Equatable, Sendable {
  let toneCounts: [SessionTimelineTone: Int]
  let eventTypes: [SessionTimelineFacetOption]
  let agents: [SessionTimelineFacetOption]
  let tasks: [SessionTimelineFacetOption]
  let decisionSeverities: [SessionTimelineFacetOption]
  let semanticProperties: [SessionTimelineFacetOption]
  let rawPayloadKeys: [SessionTimelineFacetOption]

  static let empty = Self(
    toneCounts: [:],
    eventTypes: [],
    agents: [],
    tasks: [],
    decisionSeverities: [],
    semanticProperties: [],
    rawPayloadKeys: []
  )

  func count(for tone: SessionTimelineTone) -> Int {
    toneCounts[tone] ?? 0
  }
}

struct SessionTimelineFilterSummary: Equatable, Sendable {
  let isFiltered: Bool
  let activeFilterCount: Int
  let matchCount: Int
  let loadedItemCount: Int
  let statusText: String
  let accessibilityText: String
  let accessibilityState: String

  private init(
    isFiltered: Bool,
    activeFilterCount: Int,
    matchCount: Int,
    loadedItemCount: Int,
    statusText: String,
    accessibilityText: String,
    accessibilityState: String
  ) {
    self.isFiltered = isFiltered
    self.activeFilterCount = activeFilterCount
    self.matchCount = matchCount
    self.loadedItemCount = loadedItemCount
    self.statusText = statusText
    self.accessibilityText = accessibilityText
    self.accessibilityState = accessibilityState
  }

  static let empty = Self(
    isFiltered: false,
    activeFilterCount: 0,
    matchCount: 0,
    loadedItemCount: 0,
    statusText: "",
    accessibilityText: "",
    accessibilityState: Self.accessibilityStateDescription(
      filters: SessionTimelineFilterState(),
      matchCount: 0
    )
  )

  init(
    filters: SessionTimelineFilterState,
    matchCount: Int,
    loadedItemCount: Int
  ) {
    let clampedMatchCount = max(0, matchCount)
    let clampedLoadedCount = max(0, loadedItemCount)
    let activeFilterCount = filters.activeFilterCount
    isFiltered = !filters.isEmpty
    self.activeFilterCount = activeFilterCount
    self.matchCount = clampedMatchCount
    self.loadedItemCount = clampedLoadedCount
    if isFiltered {
      let filterLabel = Self.countLabel(
        activeFilterCount,
        singular: "filter",
        plural: "filters"
      )
      let matchLabel = Self.countLabel(
        clampedMatchCount,
        singular: "match",
        plural: "matches"
      )
      let loadedLabel = Self.countLabel(
        clampedLoadedCount,
        singular: "loaded item",
        plural: "loaded items"
      )
      statusText = "\(filterLabel) • \(matchLabel) in \(loadedLabel)"
      accessibilityText =
        "\(filterLabel) active, \(matchLabel) in \(loadedLabel)"
    } else {
      statusText = ""
      accessibilityText = ""
    }
    accessibilityState = Self.accessibilityStateDescription(
      filters: filters,
      matchCount: clampedMatchCount
    )
  }

  private static func countLabel(
    _ count: Int,
    singular: String,
    plural: String
  ) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural)"
  }

  private static func accessibilityStateDescription(
    filters: SessionTimelineFilterState,
    matchCount: Int
  ) -> String {
    [
      "query=\(filters.trimmedQuery.isEmpty ? "none" : filters.trimmedQuery)",
      "scope=\(filters.searchScope.rawValue)",
      "tones=\(Self.stateValue(filters.tones.map(\.rawValue)))",
      "types=\(Self.stateValue(filters.eventTypes))",
      "agents=\(Self.stateValue(filters.agents))",
      "tasks=\(Self.stateValue(filters.tasks))",
      "severities=\(Self.stateValue(filters.decisionSeverities))",
      "semantic=\(Self.stateValue(filters.semanticProperties.map(\.rawValue)))",
      "keys=\(Self.stateValue(filters.rawPayloadKeys))",
      "matches=\(matchCount)",
    ]
    .joined(separator: ";")
  }

  private static func stateValue<S: Sequence>(_ values: S) -> String where S.Element == String {
    let sorted = values.sorted()
    return sorted.isEmpty ? "all" : sorted.joined(separator: ",")
  }
}

struct SessionTimelineFilterSnapshot: Equatable, Sendable {
  let sourceNodeCount: Int
  let filteredNodeCount: Int
  let rows: [SessionTimelineRow]
  let nodes: [SessionTimelineNode]
  let inventory: SessionTimelineFilterInventory
  let summary: SessionTimelineFilterSummary

  private init(
    sourceNodeCount: Int,
    filteredNodeCount: Int,
    rows: [SessionTimelineRow],
    nodes: [SessionTimelineNode],
    inventory: SessionTimelineFilterInventory,
    summary: SessionTimelineFilterSummary
  ) {
    self.sourceNodeCount = sourceNodeCount
    self.filteredNodeCount = filteredNodeCount
    self.rows = rows
    self.nodes = nodes
    self.inventory = inventory
    self.summary = summary
  }

  static let empty = Self(
    sourceNodeCount: 0,
    filteredNodeCount: 0,
    rows: [],
    nodes: [],
    inventory: .empty,
    summary: .empty
  )

  init(
    nodes sourceNodes: [SessionTimelineNode],
    filters: SessionTimelineFilterState,
    configuration: HarnessMonitorDateTimeConfiguration
  ) {
    let matcher = SessionTimelineFilterMatcher(filters: filters)
    sourceNodeCount = sourceNodes.count
    inventory = SessionTimelineFilterInventory(nodes: sourceNodes, matcher: matcher)
    let filteredNodes = sourceNodes.filter { node in
      matcher.matches(node)
    }
    filteredNodeCount = filteredNodes.count
    nodes = filteredNodes
    rows = SessionTimelineRow.rows(for: filteredNodes, configuration: configuration)
    summary = SessionTimelineFilterSummary(
      filters: filters,
      matchCount: filteredNodes.count,
      loadedItemCount: sourceNodes.count
    )
  }

  static func matches(
    node: SessionTimelineNode,
    filters: SessionTimelineFilterState
  ) -> Bool {
    SessionTimelineFilterMatcher(filters: filters).matches(node)
  }
}

struct SessionTimelineFilterMatcher {
  let filters: SessionTimelineFilterState
  private let trimmedQuery: String

  init(filters: SessionTimelineFilterState) {
    self.filters = filters
    trimmedQuery = filters.trimmedQuery
  }

  func matches(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingTone(_ node: SessionTimelineNode) -> Bool {
    matchesEventType(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingEventType(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingAgent(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingTask(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesAgent(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingDecisionSeverity(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesSemanticProperties(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingSemanticProperties(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesRawPayloadKeys(node)
      && matchesQuery(node)
  }

  func matchesExcludingRawPayloadKeys(_ node: SessionTimelineNode) -> Bool {
    matchesTone(node)
      && matchesEventType(node)
      && matchesAgent(node)
      && matchesTask(node)
      && matchesDecisionSeverity(node)
      && matchesSemanticProperties(node)
      && matchesQuery(node)
  }

  private func matchesTone(_ node: SessionTimelineNode) -> Bool {
    matches(filters.tones, value: node.eventTone)
  }

  private func matchesEventType(_ node: SessionTimelineNode) -> Bool {
    matches(filters.eventTypes, value: node.entryKind)
  }

  private func matchesAgent(_ node: SessionTimelineNode) -> Bool {
    matches(filters.agents, value: node.agentID)
  }

  private func matchesTask(_ node: SessionTimelineNode) -> Bool {
    matches(filters.tasks, value: node.taskID)
  }

  private func matchesDecisionSeverity(_ node: SessionTimelineNode) -> Bool {
    matches(filters.decisionSeverities, value: node.decision?.severity.rawValue)
  }

  private func matchesSemanticProperties(_ node: SessionTimelineNode) -> Bool {
    matchesAny(filters.semanticProperties, values: node.semanticProperties)
  }

  private func matchesRawPayloadKeys(_ node: SessionTimelineNode) -> Bool {
    matchesAny(filters.rawPayloadKeys, values: node.rawPayloadKeys)
  }

  private func matchesQuery(_ node: SessionTimelineNode) -> Bool {
    trimmedQuery.isEmpty || node.matches(query: trimmedQuery, scope: filters.searchScope)
  }

  private func matches<T: Hashable>(_ selected: Set<T>, value: T?) -> Bool {
    selected.isEmpty || value.map(selected.contains) == true
  }

  private func matchesAny<T: Hashable>(_ selected: Set<T>, values: Set<T>) -> Bool {
    selected.isEmpty || !values.isDisjoint(with: selected)
  }
}
