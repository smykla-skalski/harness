import Foundation

@testable import HarnessMonitorKit

/// Minimal fake used by Monitor supervisor tests that need to assert how the
/// `PolicyExecutor` routes actions to the daemon API without a live transport.
/// Records one call per dispatched action so tests can snapshot ordering and payloads.
///
/// Conforms to `SupervisorAPIClient` so the executor can stay decoupled from the
/// full `HarnessMonitorClientProtocol` surface.
final class FakeAPIClient: @unchecked Sendable, SupervisorAPIClient {
  struct NudgeCall: Equatable, Sendable {
    let agentID: String
    let input: String
  }

  struct AssignCall: Equatable, Sendable {
    let taskID: String
    let agentID: String
  }

  struct DropCall: Equatable, Sendable {
    let taskID: String
    let reason: String
  }

  struct NotifyCall: Equatable, Sendable {
    let ruleID: String
    let severity: DecisionSeverity
    let summary: String
  }

  private let queue = DispatchQueue(label: "io.harnessmonitor.tests.fake-api")
  private var _nudgeCalls: [NudgeCall] = []
  private var _assignCalls: [AssignCall] = []
  private var _dropCalls: [DropCall] = []
  private var _notifyCalls: [NotifyCall] = []

  /// When non-nil, the next `nudgeAgent` call throws this error instead of recording.
  var nudgeFailure: Error?

  var nudgeCalls: [NudgeCall] { queue.sync { _nudgeCalls } }
  var assignCalls: [AssignCall] { queue.sync { _assignCalls } }
  var dropCalls: [DropCall] { queue.sync { _dropCalls } }
  var notifyCalls: [NotifyCall] { queue.sync { _notifyCalls } }

  func nudgeAgent(agentID: String, input: String) async throws {
    if let failure = nudgeFailure { throw failure }
    queue.sync { _nudgeCalls.append(.init(agentID: agentID, input: input)) }
  }

  func assignTask(taskID: String, agentID: String) async throws {
    queue.sync { _assignCalls.append(.init(taskID: taskID, agentID: agentID)) }
  }

  func dropTask(taskID: String, reason: String) async throws {
    queue.sync { _dropCalls.append(.init(taskID: taskID, reason: reason)) }
  }

  func postNotification(
    ruleID: String,
    severity: DecisionSeverity,
    summary: String
  ) async {
    queue.sync {
      _notifyCalls.append(.init(ruleID: ruleID, severity: severity, summary: summary))
    }
  }
}
