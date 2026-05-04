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
    accessibilityState: "query=none;scope=all;tones=all;types=all;agents=all;tasks=all;severities=all;semantic=all;keys=all;matches=0"
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
      let filterLabel = activeFilterCount == 1 ? "1 filter" : "\(activeFilterCount) filters"
      let matchLabel = clampedMatchCount == 1 ? "1 match" : "\(clampedMatchCount) matches"
      let loadedLabel = clampedLoadedCount == 1 ? "1 loaded item" : "\(clampedLoadedCount) loaded items"
      statusText = "\(filterLabel) • \(matchLabel) in \(loadedLabel)"
      accessibilityText =
        "\(filterLabel) active, \(matchLabel) in \(loadedLabel)"
    } else {
      statusText = ""
      accessibilityText = ""
    }
    accessibilityState = [
      "query=\(filters.trimmedQuery.isEmpty ? "none" : filters.trimmedQuery)",
      "scope=\(filters.searchScope.rawValue)",
      "tones=\(Self.stateValue(filters.tones.map(\.rawValue)))",
      "types=\(Self.stateValue(filters.eventTypes))",
      "agents=\(Self.stateValue(filters.agents))",
      "tasks=\(Self.stateValue(filters.tasks))",
      "severities=\(Self.stateValue(filters.decisionSeverities))",
      "semantic=\(Self.stateValue(filters.semanticProperties.map(\.rawValue)))",
      "keys=\(Self.stateValue(filters.rawPayloadKeys))",
      "matches=\(clampedMatchCount)",
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

  @MainActor
  init(
    nodes sourceNodes: [SessionTimelineNode],
    filters: SessionTimelineFilterState,
    configuration: HarnessMonitorDateTimeConfiguration
  ) {
    sourceNodeCount = sourceNodes.count
    inventory = SessionTimelineFilterInventory(nodes: sourceNodes, filters: filters)
    let filteredNodes = sourceNodes.filter { node in
      Self.matches(node: node, filters: filters)
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

  private static func matches(
    node: SessionTimelineNode,
    filters: SessionTimelineFilterState
  ) -> Bool {
    if !filters.tones.isEmpty {
      guard let eventTone = node.eventTone, filters.tones.contains(eventTone) else {
        return false
      }
    }

    if !filters.eventTypes.isEmpty {
      guard let entryKind = node.entryKind, filters.eventTypes.contains(entryKind) else {
        return false
      }
    }

    if !filters.agents.isEmpty {
      guard let agentID = node.agentID, filters.agents.contains(agentID) else {
        return false
      }
    }

    if !filters.tasks.isEmpty {
      guard let taskID = node.taskID, filters.tasks.contains(taskID) else {
        return false
      }
    }

    if !filters.decisionSeverities.isEmpty {
      guard
        let severity = node.decision?.severity.rawValue,
        filters.decisionSeverities.contains(severity)
      else {
        return false
      }
    }

    if !filters.semanticProperties.isEmpty,
      node.semanticProperties.isDisjoint(with: filters.semanticProperties)
    {
      return false
    }

    if !filters.rawPayloadKeys.isEmpty,
      node.rawPayloadKeys.isDisjoint(with: filters.rawPayloadKeys)
    {
      return false
    }

    let trimmedQuery = filters.trimmedQuery
    if !trimmedQuery.isEmpty {
      return node.matches(query: trimmedQuery, scope: filters.searchScope)
    }

    return true
  }
}

private extension SessionTimelineFilterInventory {
  init(nodes: [SessionTimelineNode], filters: SessionTimelineFilterState) {
    var toneCounts: [SessionTimelineTone: Int] = [:]
    var eventTypeCounts: [String: Int] = [:]
    var agentCounts: [String: Int] = [:]
    var taskCounts: [String: Int] = [:]
    var severityCounts: [String: Int] = [:]
    var semanticPropertyCounts: [SessionTimelineSemanticProperty: Int] = [:]
    var rawKeyCounts: [String: Int] = [:]

    for node in nodes {
      if let eventTone = node.eventTone {
        toneCounts[eventTone, default: 0] += 1
      }
      if let entryKind = node.entryKind {
        eventTypeCounts[entryKind, default: 0] += 1
      }
      if let agentID = node.agentID {
        agentCounts[agentID, default: 0] += 1
      }
      if let taskID = node.taskID {
        taskCounts[taskID, default: 0] += 1
      }
      if let severity = node.decision?.severity {
        severityCounts[severity.rawValue, default: 0] += 1
      }
      for property in node.semanticProperties {
        semanticPropertyCounts[property, default: 0] += 1
      }
      for rawKey in node.rawPayloadKeys {
        rawKeyCounts[rawKey, default: 0] += 1
      }
    }

    self.toneCounts = toneCounts
    eventTypes = Self.options(
      counts: eventTypeCounts,
      selected: filters.eventTypes,
      label: Self.humanizedEventType
    )
    agents = Self.options(counts: agentCounts, selected: filters.agents, label: { $0 })
    tasks = Self.options(counts: taskCounts, selected: filters.tasks, label: { $0 })
    decisionSeverities = Self.severityOptions(
      counts: severityCounts,
      selected: filters.decisionSeverities
    )
    semanticProperties = Self.semanticPropertyOptions(
      counts: semanticPropertyCounts,
      selected: filters.semanticProperties
    )
    rawPayloadKeys = Self.options(
      counts: rawKeyCounts,
      selected: filters.rawPayloadKeys,
      label: { $0 }
    )
  }

  static func options(
    counts: [String: Int],
    selected: Set<String>,
    label: (String) -> String
  ) -> [SessionTimelineFacetOption] {
    var merged = counts
    for value in selected {
      merged[value] = merged[value] ?? 0
    }
    return merged
      .map { key, count in
        SessionTimelineFacetOption(id: key, label: label(key), count: count)
      }
      .sorted(by: facetOrdering)
  }

  static func severityOptions(
    counts: [String: Int],
    selected: Set<String>
  ) -> [SessionTimelineFacetOption] {
    var merged = counts
    for value in selected {
      merged[value] = merged[value] ?? 0
    }
    return DecisionSeverity.sidebarOrdering.compactMap { severity in
      guard let count = merged[severity.rawValue] else {
        return nil
      }
      return SessionTimelineFacetOption(
        id: severity.rawValue,
        label: severity.chipLabel,
        count: count
      )
    }
  }

  static func semanticPropertyOptions(
    counts: [SessionTimelineSemanticProperty: Int],
    selected: Set<SessionTimelineSemanticProperty>
  ) -> [SessionTimelineFacetOption] {
    let merged = Set(counts.keys).union(selected)
    return SessionTimelineSemanticProperty.allCases.compactMap { property in
      guard merged.contains(property) else {
        return nil
      }
      return SessionTimelineFacetOption(
        id: property.rawValue,
        label: property.label,
        count: counts[property] ?? 0
      )
    }
  }

  static func facetOrdering(_ lhs: SessionTimelineFacetOption, _ rhs: SessionTimelineFacetOption)
    -> Bool
  {
    if lhs.count != rhs.count {
      return lhs.count > rhs.count
    }
    return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
  }

  static func humanizedEventType(_ rawValue: String) -> String {
    rawValue
      .split(whereSeparator: { $0 == "_" || $0 == "-" })
      .map { segment in
        segment.prefix(1).uppercased() + segment.dropFirst().lowercased()
      }
      .joined(separator: " ")
  }
}

private extension SessionTimelineNode {
  func matches(query trimmedQuery: String, scope: SessionTimelineSearchScope) -> Bool {
    let needles = searchTokens(for: scope)
    return needles.contains { token in
      token.range(of: trimmedQuery, options: .caseInsensitive) != nil
    }
  }

  func searchTokens(for scope: SessionTimelineSearchScope) -> [String] {
    switch scope {
    case .all:
      summaryTokens + sourceTokens + agentTokens + taskTokens + propertyTokens
    case .summary:
      summaryTokens
    case .source:
      sourceTokens
    case .agent:
      agentTokens
    case .task:
      taskTokens
    case .properties:
      propertyTokens
    }
  }

  private var summaryTokens: [String] {
    [title, detail, decision?.summary].compactMap { value in
      guard let value, !value.isEmpty else {
        return nil
      }
      return value
    }
  }

  private var sourceTokens: [String] {
    [sourceLabel, entryKind].compactMap { value in
      guard let value, !value.isEmpty else {
        return nil
      }
      return value
    }
  }

  private var agentTokens: [String] {
    [agentID, toolCallMetadata?.agentID, toolCallMetadata?.acpAgentID, toolCallMetadata?.agentDisplayName]
      .compactMap { value in
        guard let value, !value.isEmpty else {
          return nil
        }
        return value
      }
  }

  private var taskTokens: [String] {
    [taskID].compactMap { value in
      guard let value, !value.isEmpty else {
        return nil
      }
      return value
    }
  }

  private var propertyTokens: [String] {
    var tokens = rawPayloadKeys.sorted()
    tokens += semanticProperties.map(\.label)
    if let toolName = toolCallMetadata?.toolName, !toolName.isEmpty {
      tokens.append(toolName)
    }
    if let stopReason = toolCallMetadata?.stopReason, !stopReason.isEmpty {
      tokens.append(stopReason)
    }
    tokens += toolCallMetadata?.capabilityTags ?? []
    return tokens
  }
}
