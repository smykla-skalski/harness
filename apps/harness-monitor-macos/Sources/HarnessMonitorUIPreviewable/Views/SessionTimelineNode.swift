import Foundation
import HarnessMonitorKit

enum SessionTimelineTone: String, CaseIterable, Equatable, Sendable {
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
    // signal_* rows carry status in their summary text, not in the kind string.
    if entry.kind.hasPrefix("signal_") {
      return tone(for: entry.summary)
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
      || value.contains("retry") || value.contains("expired") || value.contains("deferred")
    {
      return .warning
    }
    if value.contains("success") || value.contains("complete") || value.contains("accepted")
      || value.contains("approved") || value.contains("delivered")
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
  let entryKind: String?
  let title: String
  let detail: String?
  let agentID: String?
  let taskID: String?
  let eventTone: SessionTimelineTone?
  let decision: SessionTimelineDecisionSnapshot?
  let semanticProperties: Set<SessionTimelineSemanticProperty>
  let rawPayloadKeys: Set<String>
  let toolCallMetadata: ToolCallTimelineEntryMetadata?
  let signalID: String?

  init(
    identity: Identity,
    kind: Kind,
    timestamp: Date,
    rawTimestamp: String?,
    sourceLabel: String,
    entryKind: String? = nil,
    title: String,
    detail: String?,
    agentID: String? = nil,
    taskID: String? = nil,
    eventTone: SessionTimelineTone?,
    decision: SessionTimelineDecisionSnapshot?,
    semanticProperties: Set<SessionTimelineSemanticProperty> = [],
    rawPayloadKeys: Set<String> = [],
    toolCallMetadata: ToolCallTimelineEntryMetadata? = nil,
    signalID: String? = nil
  ) {
    self.identity = identity
    self.kind = kind
    self.timestamp = timestamp
    self.rawTimestamp = rawTimestamp
    self.sourceLabel = sourceLabel
    self.entryKind = entryKind
    self.title = title
    self.detail = detail
    self.agentID = agentID
    self.taskID = taskID
    self.eventTone = eventTone
    self.decision = decision
    self.semanticProperties = semanticProperties
    self.rawPayloadKeys = rawPayloadKeys
    self.toolCallMetadata = toolCallMetadata
    self.signalID = signalID
  }

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
