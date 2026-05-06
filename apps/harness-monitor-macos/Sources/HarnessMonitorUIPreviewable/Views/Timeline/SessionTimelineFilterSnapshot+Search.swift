import HarnessMonitorKit

extension SessionTimelineNode {
  func matches(
    query trimmedQuery: String,
    scope: SessionTimelineSearchScope
  ) -> Bool {
    let needles = searchTokens(for: scope)
    return needles.contains { token in
      token.range(of: trimmedQuery, options: .caseInsensitive) != nil
    }
  }

  fileprivate func searchTokens(for scope: SessionTimelineSearchScope) -> [String] {
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

  fileprivate var summaryTokens: [String] {
    Self.nonEmptyTokens([title, detail, decision?.summary])
  }

  fileprivate var sourceTokens: [String] {
    Self.nonEmptyTokens([sourceLabel, entryKind])
  }

  fileprivate var agentTokens: [String] {
    Self.nonEmptyTokens([
      agentID,
      toolCallMetadata?.agentID,
      toolCallMetadata?.acpAgentID,
      toolCallMetadata?.agentDisplayName,
    ])
  }

  fileprivate var taskTokens: [String] {
    Self.nonEmptyTokens([taskID])
  }

  fileprivate var propertyTokens: [String] {
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

  fileprivate static func nonEmptyTokens(_ values: [String?]) -> [String] {
    values.compactMap { value in
      guard let value, !value.isEmpty else {
        return nil
      }
      return value
    }
  }
}
