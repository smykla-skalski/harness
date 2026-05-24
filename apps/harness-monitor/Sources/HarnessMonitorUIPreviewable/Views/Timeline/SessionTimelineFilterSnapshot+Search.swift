import HarnessMonitorKit

extension SessionTimelineNode {
  func matches(
    query trimmedQuery: String,
    scope: SessionTimelineSearchScope
  ) -> Bool {
    guard !trimmedQuery.isEmpty else {
      return true
    }
    switch scope {
    case .all:
      return matchesSummary(query: trimmedQuery)
        || matchesSource(query: trimmedQuery)
        || matchesAgent(query: trimmedQuery)
        || matchesTask(query: trimmedQuery)
        || matchesProperties(query: trimmedQuery)
    case .summary:
      return matchesSummary(query: trimmedQuery)
    case .source:
      return matchesSource(query: trimmedQuery)
    case .agent:
      return matchesAgent(query: trimmedQuery)
    case .task:
      return matchesTask(query: trimmedQuery)
    case .properties:
      return matchesProperties(query: trimmedQuery)
    }
  }

  private func matchesSummary(query: String) -> Bool {
    contains(title, query: query)
      || contains(detail, query: query)
      || contains(decision?.summary, query: query)
  }

  private func matchesSource(query: String) -> Bool {
    contains(sourceLabel, query: query)
      || contains(entryKind, query: query)
  }

  private func matchesAgent(query: String) -> Bool {
    contains(agentID, query: query)
      || contains(toolCallMetadata?.agentID, query: query)
      || contains(toolCallMetadata?.acpAgentID, query: query)
      || contains(toolCallMetadata?.agentDisplayName, query: query)
  }

  private func matchesTask(query: String) -> Bool {
    contains(taskID, query: query)
  }

  private func matchesProperties(query: String) -> Bool {
    rawPayloadKeys.contains { contains($0, query: query) }
      || semanticProperties.contains { contains($0.label, query: query) }
      || contains(toolCallMetadata?.toolName, query: query)
      || contains(toolCallMetadata?.stopReason, query: query)
      || (toolCallMetadata?.capabilityTags.contains { contains($0, query: query) } ?? false)
  }

  private func contains(_ value: String?, query: String) -> Bool {
    guard let value, !value.isEmpty else {
      return false
    }
    return value.range(of: query, options: .caseInsensitive) != nil
  }
}
