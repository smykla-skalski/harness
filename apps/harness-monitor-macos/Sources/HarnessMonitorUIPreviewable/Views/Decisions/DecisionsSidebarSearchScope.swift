import HarnessMonitorKit
import SwiftUI

/// Scope the Decisions sidebar search field matches against. Persisted between sessions so
/// the last scope the operator picked comes back the way they left it.
public enum DecisionsSidebarSearchScope: String, CaseIterable, Identifiable {
  case summary
  case ruleID
  case agent
  case task

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .summary: "Summary"
    case .ruleID: "Rule ID"
    case .agent: "Agent"
    case .task: "Task"
    }
  }

  public var systemImage: String {
    switch self {
    case .summary: "text.alignleft"
    case .ruleID: "number"
    case .agent: "person.crop.circle"
    case .task: "checklist"
    }
  }

  func matches(_ decision: Decision, trimmedQuery: String) -> Bool {
    guard !trimmedQuery.isEmpty else { return true }
    let haystack: String?
    switch self {
    case .summary:
      haystack = decision.summary
    case .ruleID:
      haystack = decision.ruleID
    case .agent:
      haystack = decision.agentID
    case .task:
      haystack = decision.taskID
    }
    guard let haystack else { return false }
    return haystack.range(of: trimmedQuery, options: .caseInsensitive) != nil
  }
}
