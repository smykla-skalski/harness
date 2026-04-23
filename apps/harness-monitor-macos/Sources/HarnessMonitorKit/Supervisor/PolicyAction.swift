import Foundation

/// Exhaustive set of actions a Monitor supervisor rule can emit. The `actionKey` prefixes stay
/// stable while tick-bound actions key on `snapshotHash` so equivalent snapshots dedupe across
/// ticks. Payloads still carry `snapshotID` for audit/log correlation.
public enum PolicyAction: Sendable, Codable, Hashable {
  case nudgeAgent(NudgePayload)
  case assignTask(AssignPayload)
  case dropTask(DropPayload)
  case queueDecision(DecisionPayload)
  case notifyOnly(NotifyPayload)
  case logEvent(LogPayload)
  case suggestConfigChange(ConfigSuggestion)

  public var actionKey: String {
    switch self {
    case .nudgeAgent(let payload):
      return "nudge:\(payload.ruleID):\(payload.agentID):\(payload.snapshotHash)"
    case .assignTask(let payload):
      return "assign:\(payload.ruleID):\(payload.taskID):\(payload.snapshotHash)"
    case .dropTask(let payload):
      return "drop:\(payload.ruleID):\(payload.taskID):\(payload.snapshotHash)"
    case .queueDecision(let payload):
      return "decision:\(payload.ruleID):\(payload.id)"
    case .notifyOnly(let payload):
      return "notify:\(payload.ruleID):\(payload.snapshotHash)"
    case .logEvent(let payload):
      return "log:\(payload.ruleID):\(payload.id)"
    case .suggestConfigChange(let payload):
      return "suggest:\(payload.id)"
    }
  }

  public struct NudgePayload: Codable, Sendable, Hashable {
    public let agentID: String
    public let prompt: String
    public let ruleID: String
    public let snapshotID: String
    public let snapshotHash: String

    public init(
      agentID: String,
      prompt: String,
      ruleID: String,
      snapshotID: String,
      snapshotHash: String
    ) {
      self.agentID = agentID
      self.prompt = prompt
      self.ruleID = ruleID
      self.snapshotID = snapshotID
      self.snapshotHash = snapshotHash
    }
  }

  public struct AssignPayload: Codable, Sendable, Hashable {
    public let taskID: String
    public let agentID: String
    public let ruleID: String
    public let snapshotID: String
    public let snapshotHash: String

    public init(
      taskID: String,
      agentID: String,
      ruleID: String,
      snapshotID: String,
      snapshotHash: String
    ) {
      self.taskID = taskID
      self.agentID = agentID
      self.ruleID = ruleID
      self.snapshotID = snapshotID
      self.snapshotHash = snapshotHash
    }
  }

  public struct DropPayload: Codable, Sendable, Hashable {
    public let taskID: String
    public let reason: String
    public let ruleID: String
    public let snapshotID: String
    public let snapshotHash: String

    public init(
      taskID: String,
      reason: String,
      ruleID: String,
      snapshotID: String,
      snapshotHash: String
    ) {
      self.taskID = taskID
      self.reason = reason
      self.ruleID = ruleID
      self.snapshotID = snapshotID
      self.snapshotHash = snapshotHash
    }
  }

  public struct DecisionPayload: Codable, Sendable, Hashable {
    public let id: String
    public let severity: DecisionSeverity
    public let ruleID: String
    public let sessionID: String?
    public let agentID: String?
    public let taskID: String?
    public let summary: String
    public let contextJSON: String
    public let suggestedActionsJSON: String

    public init(
      id: String,
      severity: DecisionSeverity,
      ruleID: String,
      sessionID: String?,
      agentID: String?,
      taskID: String?,
      summary: String,
      contextJSON: String,
      suggestedActionsJSON: String
    ) {
      self.id = id
      self.severity = severity
      self.ruleID = ruleID
      self.sessionID = sessionID
      self.agentID = agentID
      self.taskID = taskID
      self.summary = summary
      self.contextJSON = contextJSON
      self.suggestedActionsJSON = suggestedActionsJSON
    }
  }

  public struct NotifyPayload: Codable, Sendable, Hashable {
    public let ruleID: String
    public let snapshotID: String
    public let snapshotHash: String
    public let severity: DecisionSeverity
    public let summary: String

    public init(
      ruleID: String,
      snapshotID: String,
      snapshotHash: String,
      severity: DecisionSeverity,
      summary: String
    ) {
      self.ruleID = ruleID
      self.snapshotID = snapshotID
      self.snapshotHash = snapshotHash
      self.severity = severity
      self.summary = summary
    }
  }

  public struct LogPayload: Codable, Sendable, Hashable {
    public let id: String
    public let ruleID: String
    public let snapshotID: String
    public let message: String

    public init(id: String, ruleID: String, snapshotID: String, message: String) {
      self.id = id
      self.ruleID = ruleID
      self.snapshotID = snapshotID
      self.message = message
    }
  }

  public struct ConfigSuggestion: Codable, Sendable, Hashable {
    public let id: String
    public let ruleID: String
    public let proposalJSON: String
    public let rationale: String

    public init(id: String, ruleID: String, proposalJSON: String, rationale: String) {
      self.id = id
      self.ruleID = ruleID
      self.proposalJSON = proposalJSON
      self.rationale = rationale
    }
  }
}
