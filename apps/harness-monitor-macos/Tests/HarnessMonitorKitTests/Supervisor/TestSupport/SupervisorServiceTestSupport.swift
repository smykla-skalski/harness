import Foundation

@testable import HarnessMonitorKit

struct EmitOnceRule: PolicyRule {
  static let ruleID = "test.emit-once"
  let id: String = ruleID
  let name: String = "Emit Once"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    [
      .logEvent(
        .init(
          id: "emit-\(snapshot.id)",
          ruleID: id,
          snapshotID: snapshot.id,
          message: "emit-once"
        ))
    ]
  }
}

struct NoopRule: PolicyRule {
  let id: String
  let name: String = "Noop"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    []
  }
}

struct ContextRecordingRule: PolicyRule {
  let id: String
  let name: String = "Context Recording"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  let recorder: ContextRecorder
  var emittedActionID: String?

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    await recorder.record(context)
    guard let emittedActionID else {
      return []
    }
    return [
      .logEvent(
        .init(
          id: emittedActionID,
          ruleID: id,
          snapshotID: snapshot.id,
          message: "record-context"
        )
      )
    ]
  }
}

actor ContextRecorder {
  private var contexts: [PolicyContext] = []

  func record(_ context: PolicyContext) {
    contexts.append(context)
  }

  func snapshot() -> [PolicyContext] {
    contexts
  }
}

struct SlowRule: PolicyRule {
  static let ruleID = "test.slow"
  let id: String = ruleID
  let name: String = "Slow"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  let gate: RuleGate

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    await gate.wait()
    return []
  }
}

struct AutoActionRule: PolicyRule {
  let id: String = "test.auto-action"
  let name: String = "Auto Action"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [PolicyAction] {
    [
      .nudgeAgent(
        .init(
          agentID: "agent-1",
          prompt: "wake up",
          ruleID: id,
          snapshotID: snapshot.id,
          snapshotHash: snapshot.hash
        )
      ),
      .queueDecision(
        .init(
          id: "decision-auto-action",
          severity: .warn,
          ruleID: id,
          sessionID: "session-1",
          agentID: "agent-1",
          taskID: nil,
          summary: "Manual follow-up required",
          contextJSON: "{}",
          suggestedActionsJSON: "[]"
        )
      ),
    ]
  }
}

actor RuleGate {
  private var isReleased = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  var released: Bool { isReleased }
  var waitCount: Int { waiters.count }

  func wait() async {
    if isReleased { return }
    await withCheckedContinuation { cont in
      waiters.append(cont)
    }
  }

  func release() {
    isReleased = true
    let pending = waiters
    waiters.removeAll()
    for cont in pending { cont.resume() }
  }
}

actor SpyObserver: PolicyObserver {
  struct Evaluation: Sendable {
    let ruleID: String
    let actions: [PolicyAction]
  }

  struct Execution: Sendable {
    let action: PolicyAction
    let outcome: PolicyOutcome
  }

  private(set) var snapshots: [SessionsSnapshot] = []
  private(set) var evaluations: [Evaluation] = []
  private(set) var executions: [Execution] = []

  func willTick(_ snapshot: SessionsSnapshot) async {
    snapshots.append(snapshot)
  }

  func didEvaluate(rule: any PolicyRule, actions: [PolicyAction]) async {
    evaluations.append(Evaluation(ruleID: rule.id, actions: actions))
  }

  func didExecute(action: PolicyAction, outcome: PolicyOutcome) async {
    executions.append(Execution(action: action, outcome: outcome))
  }

  func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [PolicyAction.ConfigSuggestion] {
    _ = history
    return []
  }
}
