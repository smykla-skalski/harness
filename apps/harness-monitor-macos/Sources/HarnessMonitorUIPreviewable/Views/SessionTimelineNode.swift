import Foundation
import HarnessMonitorKit

enum SessionTimelineTone: String, Equatable, Sendable {
  case info
  case success
  case warning
  case critical

  var label: String {
    switch self {
    case .info:
      "Info"
    case .success:
      "Success"
    case .warning:
      "Warning"
    case .critical:
      "Critical"
    }
  }

  static func eventTone(for entry: TimelineEntry) -> Self {
    if let status = entry.toolCallTimelineEntryMetadata()?.status {
      return tone(for: status)
    }
    return tone(for: entry.kind)
  }

  private static func tone(for rawValue: String) -> Self {
    let value = rawValue.lowercased()
    if value.contains("critical") || value.contains("error") || value.contains("fail")
      || value.contains("denied") || value.contains("rejected")
    {
      return .critical
    }
    if value.contains("warn") || value.contains("blocked") || value.contains("stale")
      || value.contains("retry")
    {
      return .warning
    }
    if value.contains("success") || value.contains("complete") || value.contains("accepted")
      || value.contains("approved")
    {
      return .success
    }
    return .info
  }
}

struct SessionTimelineNode: Identifiable, Equatable, Sendable {
  enum Identity: Hashable, Sendable {
    case entry(String)
    case decision(String)

    var accessibilityToken: String {
      switch self {
      case .entry(let id):
        "entry-\(id)"
      case .decision(let id):
        "decision-\(id)"
      }
    }
  }

  enum Kind: Equatable, Sendable {
    case event
    case decision
    case linkedDecision

    var label: String {
      switch self {
      case .event:
        "Event"
      case .decision:
        "Decision"
      case .linkedDecision:
        "Linked decision"
      }
    }

    var sortPriority: Int {
      switch self {
      case .decision:
        0
      case .linkedDecision:
        1
      case .event:
        2
      }
    }
  }

  let identity: Identity
  let kind: Kind
  let timestamp: Date
  let rawTimestamp: String?
  let sourceLabel: String
  let title: String
  let detail: String?
  let eventTone: SessionTimelineTone?
  let decision: SessionTimelineDecisionSnapshot?

  var id: String {
    switch identity {
    case .entry(let entryID):
      "entry:\(entryID)"
    case .decision(let decisionID):
      "decision:\(decisionID)"
    }
  }

  var actions: [SessionTimelineAction] {
    decision?.actions ?? []
  }

  var accessibilityIdentifier: String {
    HarnessMonitorAccessibility.sessionTimelineNode(identity.accessibilityToken)
  }

  var actionAvailabilityLabel: String {
    switch actions.count {
    case 0:
      "No actions"
    case 1:
      "1 action"
    default:
      "\(actions.count) actions"
    }
  }
}
