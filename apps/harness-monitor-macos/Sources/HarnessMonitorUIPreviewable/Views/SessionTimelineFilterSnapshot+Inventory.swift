import HarnessMonitorKit

extension SessionTimelineFilterInventory {
  init(nodes: [SessionTimelineNode], filters: SessionTimelineFilterState) {
    let availability = Self.availableFacetValues(from: nodes)
    let filteredNodeSets = Self.filteredNodeSets(from: nodes, filters: filters)
    let counts = Self.counts(from: filteredNodeSets)

    toneCounts = Self.completedToneCounts(
      counts.toneCounts,
      available: availability.availableTones,
      selected: filters.tones
    )
    eventTypes = Self.options(
      counts: counts.eventTypeCounts,
      available: availability.availableEventTypes,
      selected: filters.eventTypes,
      label: Self.humanizedEventType
    )
    agents = Self.options(
      counts: counts.agentCounts,
      available: availability.availableAgents,
      selected: filters.agents,
      label: { $0 }
    )
    tasks = Self.options(
      counts: counts.taskCounts,
      available: availability.availableTasks,
      selected: filters.tasks,
      label: { $0 }
    )
    decisionSeverities = Self.severityOptions(
      counts: counts.severityCounts,
      available: availability.availableSeverities,
      selected: filters.decisionSeverities
    )
    semanticProperties = Self.semanticPropertyOptions(
      counts: counts.semanticPropertyCounts,
      available: availability.availableSemanticProperties,
      selected: filters.semanticProperties
    )
    rawPayloadKeys = Self.options(
      counts: counts.rawKeyCounts,
      available: availability.availableRawKeys,
      selected: filters.rawPayloadKeys,
      label: { $0 }
    )
  }

  private struct AvailableFacetValues {
    let availableTones: Set<SessionTimelineTone>
    let availableEventTypes: Set<String>
    let availableAgents: Set<String>
    let availableTasks: Set<String>
    let availableSeverities: Set<String>
    let availableSemanticProperties: Set<SessionTimelineSemanticProperty>
    let availableRawKeys: Set<String>
  }

  private struct FilteredNodeSets {
    let toneNodes: [SessionTimelineNode]
    let eventTypeNodes: [SessionTimelineNode]
    let agentNodes: [SessionTimelineNode]
    let taskNodes: [SessionTimelineNode]
    let severityNodes: [SessionTimelineNode]
    let semanticNodes: [SessionTimelineNode]
    let rawKeyNodes: [SessionTimelineNode]
  }

  private struct FacetCounts {
    let toneCounts: [SessionTimelineTone: Int]
    let eventTypeCounts: [String: Int]
    let agentCounts: [String: Int]
    let taskCounts: [String: Int]
    let severityCounts: [String: Int]
    let semanticPropertyCounts: [SessionTimelineSemanticProperty: Int]
    let rawKeyCounts: [String: Int]
  }

  private static func availableFacetValues(
    from nodes: [SessionTimelineNode]
  ) -> AvailableFacetValues {
    AvailableFacetValues(
      availableTones: Set(nodes.compactMap(\.eventTone)),
      availableEventTypes: Set(nodes.compactMap(\.entryKind)),
      availableAgents: Set(nodes.compactMap(\.agentID)),
      availableTasks: Set(nodes.compactMap(\.taskID)),
      availableSeverities: Set(nodes.compactMap { $0.decision?.severity.rawValue }),
      availableSemanticProperties: nodes.reduce(into: Set<SessionTimelineSemanticProperty>()) {
        $0.formUnion($1.semanticProperties)
      },
      availableRawKeys: nodes.reduce(into: Set<String>()) {
        $0.formUnion($1.rawPayloadKeys)
      }
    )
  }

  private static func filteredNodeSets(
    from nodes: [SessionTimelineNode],
    filters: SessionTimelineFilterState
  ) -> FilteredNodeSets {
    FilteredNodeSets(
      toneNodes: Self.nodes(nodes, matching: filters.removingTones()),
      eventTypeNodes: Self.nodes(nodes, matching: filters.removingEventTypes()),
      agentNodes: Self.nodes(nodes, matching: filters.removingAgents()),
      taskNodes: Self.nodes(nodes, matching: filters.removingTasks()),
      severityNodes: Self.nodes(nodes, matching: filters.removingDecisionSeverities()),
      semanticNodes: Self.nodes(nodes, matching: filters.removingSemanticProperties()),
      rawKeyNodes: Self.nodes(nodes, matching: filters.removingRawPayloadKeys())
    )
  }

  private static func counts(from filteredNodeSets: FilteredNodeSets) -> FacetCounts {
    FacetCounts(
      toneCounts: toneCounts(from: filteredNodeSets.toneNodes),
      eventTypeCounts: stringCounts(from: filteredNodeSets.eventTypeNodes, value: \.entryKind),
      agentCounts: stringCounts(from: filteredNodeSets.agentNodes, value: \.agentID),
      taskCounts: stringCounts(from: filteredNodeSets.taskNodes, value: \.taskID),
      severityCounts: severityCounts(from: filteredNodeSets.severityNodes),
      semanticPropertyCounts: semanticPropertyCounts(from: filteredNodeSets.semanticNodes),
      rawKeyCounts: rawKeyCounts(from: filteredNodeSets.rawKeyNodes)
    )
  }

  private static func completedToneCounts(
    _ counts: [SessionTimelineTone: Int],
    available: Set<SessionTimelineTone>,
    selected: Set<SessionTimelineTone>
  ) -> [SessionTimelineTone: Int] {
    var mergedCounts = counts
    for tone in available.union(selected) {
      mergedCounts[tone] = mergedCounts[tone] ?? 0
    }
    return mergedCounts
  }

  private static func toneCounts(from nodes: [SessionTimelineNode]) -> [SessionTimelineTone: Int] {
    nodes.reduce(into: [SessionTimelineTone: Int]()) { counts, node in
      guard let eventTone = node.eventTone else {
        return
      }
      counts[eventTone, default: 0] += 1
    }
  }

  private static func stringCounts(
    from nodes: [SessionTimelineNode],
    value: KeyPath<SessionTimelineNode, String?>
  ) -> [String: Int] {
    nodes.reduce(into: [String: Int]()) { counts, node in
      guard let value = node[keyPath: value] else {
        return
      }
      counts[value, default: 0] += 1
    }
  }

  private static func severityCounts(from nodes: [SessionTimelineNode]) -> [String: Int] {
    nodes.reduce(into: [String: Int]()) { counts, node in
      guard let severity = node.decision?.severity.rawValue else {
        return
      }
      counts[severity, default: 0] += 1
    }
  }

  private static func semanticPropertyCounts(
    from nodes: [SessionTimelineNode]
  ) -> [SessionTimelineSemanticProperty: Int] {
    nodes.reduce(into: [SessionTimelineSemanticProperty: Int]()) { counts, node in
      for property in node.semanticProperties {
        counts[property, default: 0] += 1
      }
    }
  }

  private static func rawKeyCounts(from nodes: [SessionTimelineNode]) -> [String: Int] {
    nodes.reduce(into: [String: Int]()) { counts, node in
      for rawKey in node.rawPayloadKeys {
        counts[rawKey, default: 0] += 1
      }
    }
  }

  fileprivate static func options(
    counts: [String: Int],
    available: Set<String>,
    selected: Set<String>,
    label: (String) -> String
  ) -> [SessionTimelineFacetOption] {
    var merged = counts
    for value in available.union(selected) {
      merged[value] = merged[value] ?? 0
    }

    let options = merged.map { key, count in
      SessionTimelineFacetOption(
        id: key,
        label: label(key),
        count: count
      )
    }
    return options.sorted(by: facetOrdering)
  }

  fileprivate static func severityOptions(
    counts: [String: Int],
    available: Set<String>,
    selected: Set<String>
  ) -> [SessionTimelineFacetOption] {
    var merged = counts
    for value in available.union(selected) {
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

  fileprivate static func semanticPropertyOptions(
    counts: [SessionTimelineSemanticProperty: Int],
    available: Set<SessionTimelineSemanticProperty>,
    selected: Set<SessionTimelineSemanticProperty>
  ) -> [SessionTimelineFacetOption] {
    let merged = available.union(selected)
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

  fileprivate static func facetOrdering(
    _ lhs: SessionTimelineFacetOption,
    _ rhs: SessionTimelineFacetOption
  )
    -> Bool
  {
    if lhs.count != rhs.count {
      return lhs.count > rhs.count
    }
    return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
  }

  fileprivate static func humanizedEventType(_ rawValue: String) -> String {
    rawValue
      .split(whereSeparator: { $0 == "_" || $0 == "-" })
      .map { segment in
        segment.prefix(1).uppercased() + segment.dropFirst().lowercased()
      }
      .joined(separator: " ")
  }

  fileprivate static func nodes(
    _ sourceNodes: [SessionTimelineNode],
    matching filters: SessionTimelineFilterState
  ) -> [SessionTimelineNode] {
    sourceNodes.filter { node in
      SessionTimelineFilterSnapshot.matches(node: node, filters: filters)
    }
  }
}
