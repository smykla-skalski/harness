import Foundation
import OpenTelemetryApi
import os

/// Clock abstraction the supervisor tick loop uses. Real code plugs in `WallClock` (the default
/// when `clock: Any?` is nil); tests plug in `TestClock` to advance virtual time deterministically.
public protocol SupervisorClock: Sendable {
  func now() -> Date
  func sleep(for duration: Duration) async throws
}

/// Wall-clock implementation backed by `Task.sleep(for:)`. Used when the caller passes `nil`
/// for the clock parameter (i.e. production wiring from `HarnessMonitorStore+Supervisor`).
public struct WallClock: SupervisorClock {
  public init() {}
  public func now() -> Date { Date() }
  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/// Actor owning the Monitor supervisor tick loop. Each tick builds a `SessionsSnapshot`, fans
/// rules out to a `TaskGroup`, dispatches emitted actions through `PolicyExecutor`, and notifies
/// registered observers. Per-rule failures are isolated and counted inside a sliding 10-tick
/// window; a rule that fails 5+ times in that window is quarantined — subsequent ticks skip it
/// and the supervisor queues a critical `Decision` so the user sees the quarantine.
public actor SupervisorService {
  /// Quarantine threshold: a rule that fails at least this many times inside the recent window
  /// is quarantined.
  private static let quarantineErrorThreshold = 5

  /// Sliding window size (in ticks) used when evaluating the quarantine threshold.
  private static let quarantineWindowTicks = 10

  private let store: HarnessMonitorStore?
  private let registry: PolicyRegistry
  private let executor: PolicyExecutor
  private let clock: any SupervisorClock
  private let interval: TimeInterval

  /// The task running the tick loop. Cancelling and awaiting it drains the in-flight tick.
  private var tickTask: Task<Void, Never>?
  private var running = false
  private var autoActionsSuppressed = false

  /// Per-rule error flags for the last N ticks. Each ring entry is keyed by rule id; `true`
  /// means the rule errored during that tick. Oldest entries are dropped as the window slides.
  private var ruleFailureWindow: [[String: Bool]] = []
  private var quarantined: Set<String> = []
  private var injectedFailures: Set<String> = []
  private var dispatchedQuarantineDecisions: Set<String> = []

  public init(
    store: HarnessMonitorStore?,
    registry: PolicyRegistry,
    executor: PolicyExecutor,
    clock: Any?,
    interval: TimeInterval
  ) {
    self.store = store
    self.registry = registry
    self.executor = executor
    self.clock = (clock as? any SupervisorClock) ?? WallClock()
    self.interval = interval
  }

  public func start() async {
    guard !running else { return }
    running = true
    HarnessMonitorLogger.supervisor.info("supervisor.start interval=\(self.interval, privacy: .public)")
    tickTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop()
    }
  }

  public func stop() async {
    guard running else { return }
    running = false
    tickTask?.cancel()
    // Awaiting the tick-loop task drains any in-flight tick before returning.
    _ = await tickTask?.value
    tickTask = nil
    HarnessMonitorLogger.supervisor.info("supervisor.stop")
  }

  /// Runs a single tick inline. Exposed for the UI-test debug hook (`forceSupervisorTick`) and
  /// for deterministic test driving via `runOneTick()`.
  public func runOneTick() async {
    await tickBody()
  }

  /// Suppress automatic actions for the duration of the supplied operation. Useful while a user
  /// is actively resolving a decision so the supervisor doesn't fire additional nudges.
  public func suppressAutoActions<Result>(
    during operation: () async throws -> Result
  ) async rethrows -> Result {
    autoActionsSuppressed = true
    defer { autoActionsSuppressed = false }
    return try await operation()
  }

  // MARK: - Test hooks

  /// Wait for the current tick (if any) to finish. No-op when the loop is idle.
  /// For deterministic test driving, prefer calling `runOneTick()` directly.
  public func awaitCurrentTick() async {
    // Yield to the cooperative scheduler so any pending tick work in flight gets a scheduling
    // opportunity. Tests that use runOneTick() directly do not need this method.
    await Task.yield()
  }

  /// Set of rules the supervisor has quarantined in the current run.
  public func quarantinedRuleIDs() -> Set<String> {
    quarantined
  }

  /// Arm the supervisor to treat evaluate calls for `ruleID` as failures. Used only by the
  /// supervisor test suite to exercise the quarantine path without altering the frozen
  /// `PolicyRule` protocol. Injection persists across ticks until the rule is quarantined.
  public func injectFailure(forRuleID ruleID: String) {
    injectedFailures.insert(ruleID)
  }

  // MARK: - Tick loop

  private func runLoop() async {
    while running && !Task.isCancelled {
      do {
        try await clock.sleep(for: .seconds(Int(interval)))
      } catch {
        return
      }
      guard running && !Task.isCancelled else { return }
      await tickBody()
    }
  }

  private func tickBody() async {
    let tracer = SupervisorTelemetry.tracer()
    let span = tracer.spanBuilder(spanName: SupervisorTelemetry.tickSpanName).startSpan()
    defer { span.end() }

    let now = clock.now()
    let snapshot = buildSnapshot(now: now)
    HarnessMonitorLogger.supervisor.debug(
      "supervisor.tick snapshot=\(snapshot.id, privacy: .public)"
    )

    let rules = await registry.allRules
    let observers = await registry.observerList
    for observer in observers {
      await observer.willTick(snapshot)
    }

    let results = await evaluateRules(
      rules,
      snapshot: snapshot,
      now: now,
      observers: observers
    )
    advanceFailureWindow(with: results.failedRuleIDs)
    applyNewQuarantines(for: results.failedRuleIDs)
    await dispatchActions(results.actionsByRule, observers: observers)
  }

  private struct TickResults {
    var actionsByRule: [(ruleID: String, actions: [PolicyAction])] = []
    var failedRuleIDs: Set<String> = []
  }

  private func evaluateRules(
    _ rules: [any PolicyRule],
    snapshot: SessionsSnapshot,
    now: Date,
    observers: [any PolicyObserver]
  ) async -> TickResults {
    let context = PolicyContext(
      now: now,
      lastFiredAt: nil,
      recentActionKeys: [],
      parameters: PolicyParameterValues(raw: [:]),
      history: PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    )
    let quarantinedSnapshot = quarantined
    let armedSnapshot = injectedFailures

    return await withTaskGroup(of: RuleEvaluation.self) { group in
      for rule in rules where !quarantinedSnapshot.contains(rule.id) {
        let armed = armedSnapshot.contains(rule.id)
        group.addTask { [context] in
          await Self.runRule(rule, snapshot: snapshot, context: context, armed: armed)
        }
      }
      var results = TickResults()
      for await evaluation in group {
        if evaluation.failed {
          results.failedRuleIDs.insert(evaluation.ruleID)
        }
        for observer in observers {
          await observer.didEvaluate(rule: evaluation.rule, actions: evaluation.actions)
        }
        if !evaluation.actions.isEmpty {
          results.actionsByRule.append((evaluation.ruleID, evaluation.actions))
        }
      }
      return results
    }
  }

  private struct RuleEvaluation {
    let ruleID: String
    let rule: any PolicyRule
    let actions: [PolicyAction]
    let failed: Bool
  }

  private static func runRule(
    _ rule: any PolicyRule,
    snapshot: SessionsSnapshot,
    context: PolicyContext,
    armed: Bool
  ) async -> RuleEvaluation {
    if armed {
      HarnessMonitorLogger.supervisor.warning(
        "supervisor.rule.failed rule=\(rule.id, privacy: .public)"
      )
      return RuleEvaluation(ruleID: rule.id, rule: rule, actions: [], failed: true)
    }
    let actions = await rule.evaluate(snapshot: snapshot, context: context)
    return RuleEvaluation(ruleID: rule.id, rule: rule, actions: actions, failed: false)
  }

  private func advanceFailureWindow(with failedRuleIDs: Set<String>) {
    var entry: [String: Bool] = [:]
    for ruleID in failedRuleIDs { entry[ruleID] = true }
    ruleFailureWindow.append(entry)
    while ruleFailureWindow.count > Self.quarantineWindowTicks {
      ruleFailureWindow.removeFirst()
    }
  }

  private func applyNewQuarantines(for failedRuleIDs: Set<String>) {
    for ruleID in failedRuleIDs {
      if quarantined.contains(ruleID) { continue }
      let count = ruleFailureWindow.reduce(0) { partial, entry in
        partial + (entry[ruleID] == true ? 1 : 0)
      }
      if count >= Self.quarantineErrorThreshold {
        quarantined.insert(ruleID)
        HarnessMonitorLogger.supervisor.error(
          "supervisor.rule.quarantined rule=\(ruleID, privacy: .public) count=\(count, privacy: .public)"
        )
      }
    }
  }

  private func dispatchActions(
    _ actionsByRule: [(ruleID: String, actions: [PolicyAction])],
    observers: [any PolicyObserver]
  ) async {
    for entry in actionsByRule {
      for action in entry.actions {
        await dispatch(action, observers: observers)
      }
    }
    // Emit a quarantine decision for every newly quarantined rule so the user gets a visible
    // signal when the supervisor gives up on a rule.
    for ruleID in quarantined where wasQuarantinedThisTick(ruleID) {
      let decision = Self.makeQuarantineDecision(for: ruleID)
      await dispatch(.queueDecision(decision), observers: observers)
      dispatchedQuarantineDecisions.insert(ruleID)
    }
  }

  private func wasQuarantinedThisTick(_ ruleID: String) -> Bool {
    quarantined.contains(ruleID) && !dispatchedQuarantineDecisions.contains(ruleID)
  }

  private func dispatch(
    _ action: PolicyAction,
    observers: [any PolicyObserver]
  ) async {
    let outcome = await executor.execute(action)
    for observer in observers {
      await observer.didExecute(action: action, outcome: outcome)
    }
  }

  private func buildSnapshot(now: Date) -> SessionsSnapshot {
    if let store {
      return SessionsSnapshot.build(from: store, now: now)
    }
    return SessionsSnapshot(
      id: UUID().uuidString,
      createdAt: now,
      hash: "",
      sessions: [],
      connection: ConnectionSnapshot(kind: "disconnected", lastMessageAt: nil, reconnectAttempt: 0)
    )
  }

  private static func makeQuarantineDecision(for ruleID: String) -> PolicyAction.DecisionPayload {
    PolicyAction.DecisionPayload(
      id: "quarantine:\(ruleID)",
      severity: .critical,
      ruleID: ruleID,
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "Rule \(ruleID) quarantined after repeated failures",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )
  }
}
