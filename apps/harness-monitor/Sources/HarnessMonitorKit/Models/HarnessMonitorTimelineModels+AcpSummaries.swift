import Foundation

/// Human-readable summaries for the ACP conversation-event kinds that carry
/// their detail inside the opaque `kind` payload.
extension AcpConversationEvent {
  static func stateChangeSummary(prefix: String, event: [String: JSONValue]) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    return "\(prefix) state changed \(from) -> \(to)"
  }

  static func fileModificationSummary(
    prefix: String,
    event: [String: JSONValue]
  ) -> String {
    let operation = event.stringValue(for: "operation") ?? "modified"
    let path = event.stringValue(for: "path") ?? "file"
    return "\(prefix) \(operation) \(path)"
  }

  static func watchdogSummary(prefix: String, event: [String: JSONValue]) -> String {
    let from = event.stringValue(for: "from") ?? "unknown"
    let to = event.stringValue(for: "to") ?? "unknown"
    let base = "\(prefix) watchdog \(from) -> \(to)"
    guard
      let reason = event.stringValue(for: "reason")?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ),
      !reason.isEmpty
    else {
      return base
    }
    return "\(base) (\(reason))"
  }

  static func permissionSummary(prefix: String, event: [String: JSONValue]) -> String {
    let tool = event.stringValue(for: "tool") ?? "tool"
    let scope = event.stringValue(for: "scope") ?? ""
    guard !scope.isEmpty else {
      return "\(prefix) asked for permission on \(tool)"
    }
    return "\(prefix) asked for permission on \(tool) (\(scope))"
  }

  static func contextSummary(prefix: String, event: [String: JSONValue]) -> String {
    let actor = event.stringValue(for: "actor") ?? "system"
    let detail = event.stringValue(for: "summary") ?? ""
    guard !detail.isEmpty else {
      return "\(prefix) received context from \(actor)"
    }
    return "\(prefix) received context from \(actor): \(detail)"
  }

  static func turnEndedSummary(prefix: String, event: [String: JSONValue]) -> String {
    switch event.stringValue(for: "stop_reason") {
    case "refusal": return "\(prefix) refused to continue the turn"
    case "cancelled": return "\(prefix) turn cancelled"
    case "max_tokens": return "\(prefix) turn hit the token limit"
    case "max_turn_requests": return "\(prefix) turn hit the request limit"
    case let other?: return "\(prefix) turn ended (\(other))"
    case nil: return "\(prefix) turn ended"
    }
  }

  static func contextUsageSummary(prefix: String, event: [String: JSONValue]) -> String {
    let used = event.uint64Value(for: "used_tokens").map(String.init) ?? "?"
    let window = event.uint64Value(for: "context_window_tokens").map(String.init) ?? "?"
    let usage = "\(prefix) used \(used) of \(window) context tokens"
    guard
      case .number(let amount)? = event["cost_amount"],
      let currency = event.stringValue(for: "cost_currency")
    else {
      return usage
    }
    return "\(usage) (\(amount) \(currency))"
  }
}
