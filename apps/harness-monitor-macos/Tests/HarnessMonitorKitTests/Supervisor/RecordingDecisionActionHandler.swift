import Foundation

@testable import HarnessMonitorKit

final class RecordingDecisionActionHandler: DecisionActionHandler, @unchecked Sendable {
  struct ResolveCall: Sendable {
    let decisionID: String
    let outcome: DecisionOutcome
  }

  struct SnoozeCall: Sendable {
    let decisionID: String
    let duration: TimeInterval
  }

  var resolvedCalls: [ResolveCall] = []
  var snoozeCalls: [SnoozeCall] = []
  var dismissCalls: [String] = []

  func resolve(decisionID: String, outcome: DecisionOutcome) async {
    resolvedCalls.append(ResolveCall(decisionID: decisionID, outcome: outcome))
  }

  func snooze(decisionID: String, duration: TimeInterval) async {
    snoozeCalls.append(SnoozeCall(decisionID: decisionID, duration: duration))
  }

  func dismiss(decisionID: String) async {
    dismissCalls.append(decisionID)
  }

  func cancelSignal(signalID: String, agentID: String) async {
    _ = (signalID, agentID)
  }

  func resendSignal(_ record: SessionSignalRecord) async {
    _ = record
  }
}
