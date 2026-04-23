import Foundation

import OSLog

public protocol SupervisorLogSink: Sendable {
  func record(event: String, fields: [String: String])
}

public struct OSLogSupervisorLogSink: SupervisorLogSink {
  public init() {}

  public func record(event: String, fields: [String: String]) {
    let renderedFields =
      fields
      .sorted { lhs, rhs in
        lhs.key < rhs.key
      }
      .map { key, value in "\(key)=\(value)" }
      .joined(separator: " ")

    HarnessMonitorLogger.supervisor.info(
      "\(event, privacy: .public) \(renderedFields, privacy: .public)"
    )
  }
}

/// Built-in observer that mirrors every tick, rule evaluation, and action outcome into
/// `HarnessMonitorLogger.supervisor`.
///
/// AI-observer extension point:
/// External code can register an `AIPolicyObserver` that conforms to `PolicyObserver` and calls
/// an AI runtime to produce `[PolicyAction.ConfigSuggestion]` from
/// `proposeConfigSuggestion(history:)`.
/// This external observer integration is documented as the v1 extension seam, but it is not
/// shipped in the product by default.
public final class LoggingPolicyObserver: PolicyObserver {
  private let sink: any SupervisorLogSink

  public init(sink: any SupervisorLogSink = OSLogSupervisorLogSink()) {
    self.sink = sink
  }

  public func willTick(_ snapshot: SessionsSnapshot) async {
    sink.record(
      event: "willTick",
      fields: [
        "tickID": snapshot.id,
        "sessionsHash": snapshot.hash,
      ]
    )
  }

  public func didEvaluate(rule: any PolicyRule, actions: [PolicyAction]) async {
    sink.record(
      event: "didEvaluate",
      fields: [
        "ruleID": rule.id,
        "actionCount": "\(actions.count)",
      ]
    )
  }

  public func didExecute(action: PolicyAction, outcome: PolicyOutcome) async {
    var fields = action.logFields
    for (key, value) in outcome.logFields {
      fields[key] = value
    }
    sink.record(event: "didExecute", fields: fields)
  }

  public func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [PolicyAction.ConfigSuggestion] {
    _ = history
    return []
  }
}

extension PolicyAction {
  fileprivate var logFields: [String: String] {
    var fields = baseLogFields
    if let snapshotID {
      fields["snapshotID"] = snapshotID
    }
    if let snapshotHash {
      fields["snapshotHash"] = snapshotHash
    }
    return fields
  }

  private var baseLogFields: [String: String] {
    switch self {
    case .nudgeAgent(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID]
    case .assignTask(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID]
    case .dropTask(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID]
    case .queueDecision(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID, "decisionID": payload.id]
    case .notifyOnly(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID]
    case .logEvent(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID, "logID": payload.id]
    case .suggestConfigChange(let payload):
      ["actionKey": actionKey, "ruleID": payload.ruleID, "suggestionID": payload.id]
    }
  }

  private var snapshotID: String? {
    switch self {
    case .nudgeAgent(let payload): payload.snapshotID
    case .assignTask(let payload): payload.snapshotID
    case .dropTask(let payload): payload.snapshotID
    case .notifyOnly(let payload): payload.snapshotID
    case .logEvent(let payload): payload.snapshotID
    case .queueDecision, .suggestConfigChange:
      nil
    }
  }

  private var snapshotHash: String? {
    switch self {
    case .nudgeAgent(let payload): payload.snapshotHash
    case .assignTask(let payload): payload.snapshotHash
    case .dropTask(let payload): payload.snapshotHash
    case .notifyOnly(let payload): payload.snapshotHash
    case .queueDecision, .logEvent, .suggestConfigChange:
      nil
    }
  }
}

extension PolicyOutcome {
  fileprivate var logFields: [String: String] {
    switch self {
    case .dispatched(let actionKey):
      [
        "actionKey": actionKey,
        "outcome": "dispatched",
      ]
    case .skippedDuplicate(let actionKey):
      [
        "actionKey": actionKey,
        "outcome": "skippedDuplicate",
      ]
    case .executed(let actionKey):
      [
        "actionKey": actionKey,
        "outcome": "executed",
      ]
    case .failed(let actionKey, let error):
      [
        "actionKey": actionKey,
        "outcome": "failed",
        "error": redactSupervisorErrorMessage(error),
      ]
    case .quarantined(let ruleID, let reason):
      [
        "ruleID": ruleID,
        "outcome": "quarantined",
        "reason": reason,
      ]
    }
  }
}
