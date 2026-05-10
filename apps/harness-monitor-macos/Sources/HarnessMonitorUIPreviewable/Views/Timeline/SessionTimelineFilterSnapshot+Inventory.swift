import HarnessMonitorKit

extension SessionTimelineFilterInventory {
  init(nodes: [SessionTimelineNode], filters: SessionTimelineFilterState) {
    self.init(nodes: nodes, matcher: SessionTimelineFilterMatcher(filters: filters))
  }

  init(nodes: [SessionTimelineNode], matcher: SessionTimelineFilterMatcher) {
    var accumulator = FacetAccumulator(matcher: matcher)
    for node in nodes {
      accumulator.record(node)
    }
    let availability = accumulator.available
    let counts = accumulator.counts
    let filters = matcher.filters

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
    var availableTones: Set<SessionTimelineTone> = []
    var availableEventTypes: Set<String> = []
    var availableAgents: Set<String> = []
    var availableTasks: Set<String> = []
    var availableSeverities: Set<String> = []
    var availableSemanticProperties: Set<SessionTimelineSemanticProperty> = []
    var availableRawKeys: Set<String> = []
  }

  private struct FacetCounts {
    var toneCounts: [SessionTimelineTone: Int] = [:]
    var eventTypeCounts: [String: Int] = [:]
    var agentCounts: [String: Int] = [:]
    var taskCounts: [String: Int] = [:]
    var severityCounts: [String: Int] = [:]
    var semanticPropertyCounts: [SessionTimelineSemanticProperty: Int] = [:]
    var rawKeyCounts: [String: Int] = [:]
  }

  private struct FacetAccumulator {
    let matcher: SessionTimelineFilterMatcher
    var available = AvailableFacetValues()
    var counts = FacetCounts()

    mutating func record(_ node: SessionTimelineNode) {
      recordAvailability(node)
      if matcher.matchesExcludingTone(node), let eventTone = node.eventTone {
        counts.toneCounts[eventTone, default: 0] += 1
      }
      if matcher.matchesExcludingEventType(node), let entryKind = node.entryKind {
        counts.eventTypeCounts[entryKind, default: 0] += 1
      }
      if matcher.matchesExcludingAgent(node), let agentID = node.agentID {
        counts.agentCounts[agentID, default: 0] += 1
      }
      if matcher.matchesExcludingTask(node), let taskID = node.taskID {
        counts.taskCounts[taskID, default: 0] += 1
      }
      if matcher.matchesExcludingDecisionSeverity(node),
        let severity = node.decision?.severity.rawValue
      {
        counts.severityCounts[severity, default: 0] += 1
      }
      if matcher.matchesExcludingSemanticProperties(node) {
        for property in node.semanticProperties {
          counts.semanticPropertyCounts[property, default: 0] += 1
        }
      }
      if matcher.matchesExcludingRawPayloadKeys(node) {
        for rawKey in node.rawPayloadKeys {
          counts.rawKeyCounts[rawKey, default: 0] += 1
        }
      }
    }

    private mutating func recordAvailability(_ node: SessionTimelineNode) {
      if let eventTone = node.eventTone {
        available.availableTones.insert(eventTone)
      }
      if let entryKind = node.entryKind {
        available.availableEventTypes.insert(entryKind)
      }
      if let agentID = node.agentID {
        available.availableAgents.insert(agentID)
      }
      if let taskID = node.taskID {
        available.availableTasks.insert(taskID)
      }
      if let severity = node.decision?.severity.rawValue {
        available.availableSeverities.insert(severity)
      }
      available.availableSemanticProperties.formUnion(node.semanticProperties)
      available.availableRawKeys.formUnion(node.rawPayloadKeys)
    }
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
}

extension SessionTimelineFilterInventory {
  var signalCount: Int {
    eventTypes
      .filter { SessionTimelineFilterState.signalEventKinds.contains($0.id) }
      .reduce(0) { $0 + $1.count }
  }
}
