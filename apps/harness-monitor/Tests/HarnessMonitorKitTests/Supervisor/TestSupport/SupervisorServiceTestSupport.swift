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
  ) async -> [SupervisorAction] {
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
  ) async -> [SupervisorAction] {
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
  ) async -> [SupervisorAction] {
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

struct DuplicateActionKeyRule: PolicyRule {
  let id: String = "test.duplicate-action-key"
  let name: String = "Duplicate Action Key"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .cautious
  }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [SupervisorAction] {
    _ = context
    let action = SupervisorAction.logEvent(
      .init(
        id: "duplicate-action",
        ruleID: id,
        snapshotID: snapshot.id,
        message: "duplicate-action-key"
      )
    )
    return [action, action]
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
  ) async -> [SupervisorAction] {
    await gate.wait()
    return []
  }
}

struct SlowEmitRule: PolicyRule {
  static let ruleID = "test.slow-emit"
  let id: String = ruleID
  let name: String = "Slow Emit"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  let gate: RuleGate

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior { .cautious }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [SupervisorAction] {
    _ = context
    await gate.wait()
    return [
      .logEvent(
        .init(id: "slow-emit", ruleID: id, snapshotID: snapshot.id, message: "slow")
      )
    ]
  }
}

struct AutoActionRule: PolicyRule {
  let id: String = "test.auto-action"
  let name: String = "Auto Action"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    actionKey.hasPrefix("nudge:") ? .aggressive : .cautious
  }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [SupervisorAction] {
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

struct AutoOnlyRule: PolicyRule {
  let id: String = "test.auto-only"
  let name: String = "Auto Only"
  let version: Int = 1
  let parameters = PolicyParameterSchema(fields: [])

  func defaultBehavior(for actionKey: String) -> RuleDefaultBehavior {
    _ = actionKey
    return .aggressive
  }

  func evaluate(
    snapshot: SessionsSnapshot,
    context: PolicyContext
  ) async -> [SupervisorAction] {
    let action = SupervisorAction.nudgeAgent(
      .init(
        agentID: "agent-1",
        prompt: "wake up",
        ruleID: id,
        snapshotID: snapshot.id,
        snapshotHash: snapshot.hash
      )
    )
    guard !context.recentActionKeys.contains(action.actionKey) else {
      return []
    }
    return [action]
  }
}

struct SuggestionObserver: PolicyObserver {
  func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [SupervisorAction.ConfigSuggestion] {
    _ = history
    return [
      .init(
        id: "suggestion-1",
        ruleID: "observer",
        proposalJSON: #"{"enabled":true}"#,
        rationale: "test suggestion"
      )
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
    let actions: [SupervisorAction]
  }

  struct Execution: Sendable {
    let action: SupervisorAction
    let outcome: PolicyOutcome
  }

  private(set) var snapshots: [SessionsSnapshot] = []
  private(set) var evaluations: [Evaluation] = []
  private(set) var executions: [Execution] = []

  func willTick(_ snapshot: SessionsSnapshot) async {
    snapshots.append(snapshot)
  }

  func didEvaluate(rule: any PolicyRule, actions: [SupervisorAction]) async {
    evaluations.append(Evaluation(ruleID: rule.id, actions: actions))
  }

  func didExecute(action: SupervisorAction, outcome: PolicyOutcome) async {
    executions.append(Execution(action: action, outcome: outcome))
  }

  func proposeConfigSuggestion(
    history: PolicyHistoryWindow
  ) async -> [SupervisorAction.ConfigSuggestion] {
    _ = history
    return []
  }
}
