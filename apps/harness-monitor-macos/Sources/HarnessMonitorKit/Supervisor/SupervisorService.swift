import Foundation
import SwiftData

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

public actor SupervisorService {
  private static let quarantineErrorThreshold = 5
  private static let quarantineWindowTicks = 10
  static let recentActionWindow: TimeInterval = 60
  weak var store: HarnessMonitorStore?
  let registry: PolicyRegistry
  private let executor: PolicyExecutor
  let clock: any SupervisorClock
  let interval: TimeInterval
  private let ruleEvaluationTimeout: Duration

  var tickTask: Task<Void, Never>?
  var running = false, tickInProgress = false
  private var tickWaiters: [CheckedContinuation<Void, Never>] = []
  var autoActionSuppressionDepth = 0
  var quietHoursWindow: SupervisorQuietHoursWindow?

  private var ruleFailureWindow: [[String: Bool]] = []
  private var quarantined: Set<String> = []
  private var injectedFailures: Set<String> = []
  private var dispatchedQuarantineDecisions: Set<String> = []
  var ruleLastFiredAt: [String: Date] = [:]
  var ruleRecentActionKeys: [String: [String: Date]] = [:]
  var ruleRecentSuppressedActionKeys: [String: [String: Date]] = [:]
  var tickLatencySamplesMs: [Double] = []
  private var lastSnapshotID: String?
  private var lastObserverCount = 0
  var fallbackDisconnectedSince: Date?
  var fallbackLastMessageAt: Date?

  public init(
    store: HarnessMonitorStore?,
    registry: PolicyRegistry,
    executor: PolicyExecutor,
    clock: Any?,
    interval: TimeInterval,
    ruleEvaluationTimeout: Duration = .seconds(5)
  ) {
    self.store = store
    self.registry = registry
    self.executor = executor
    self.clock = (clock as? any SupervisorClock) ?? WallClock()
    self.interval = interval
    self.ruleEvaluationTimeout = ruleEvaluationTimeout
  }

  public func runOneTick() async { await runTickSerialized() }

  public func suppressAutoActions<Result>(
    during operation: @Sendable () async throws -> Result
  ) async rethrows -> Result {
    autoActionSuppressionDepth += 1
    defer { autoActionSuppressionDepth = max(0, autoActionSuppressionDepth - 1) }
    return try await operation()
  }

  public func setQuietHoursWindow(_ window: SupervisorQuietHoursWindow?) {
    quietHoursWindow = window
  }

  public func awaitCurrentTick() async {
    guard tickInProgress else { return }
    await withCheckedContinuation { continuation in
      tickWaiters.append(continuation)
    }
  }

  public func quarantinedRuleIDs() -> Set<String> { quarantined }

  public func isAutoActionSuppressed(at date: Date) -> Bool { suppressionActive(at: date) }

  public func liveTickSnapshot() -> DecisionLiveTickSnapshot {
    DecisionLiveTickSnapshot(
      lastSnapshotID: lastSnapshotID,
      tickLatencyP50Ms: percentile(0.5),
      tickLatencyP95Ms: percentile(0.95),
      activeObserverCount: lastObserverCount,
      quarantinedRuleIDs: quarantined.sorted()
    )
  }

  public func injectFailure(forRuleID ruleID: String) { injectedFailures.insert(ruleID) }

  func runTickSerialized() async {
    guard !tickInProgress else {
      await awaitCurrentTick()
      return
    }
    tickInProgress = true
    await tickBody()
    tickInProgress = false
    resumeTickWaiters()
  }

  private func resumeTickWaiters() {
    let waiters = tickWaiters
    tickWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func tickBody() async {
    let tickStartedAt = clock.now()
    #if HARNESS_FEATURE_OTEL
      let tracer = SupervisorTelemetry.tracer()
      let span = tracer.spanBuilder(spanName: SupervisorTelemetry.tickSpanName).startSpan()
      defer { span.end() }
    #endif
    let now = clock.now()
    if !suppressionActive(at: now) {
      ruleRecentSuppressedActionKeys.removeAll()
    }
    let snapshot = await buildSnapshot(now: now)
    HarnessMonitorLogger.supervisorDebug("supervisor.tick snapshot=\(snapshot.id)")
    let rules = await registry.allRules
    let observers = await registry.observerList
    lastSnapshotID = snapshot.id
    lastObserverCount = observers.count
    for observer in observers {
      await observer.willTick(snapshot)
    }
    let history = await historyWindow(ruleIDs: rules.map(\.id))
    let results = await evaluateRules(
      rules,
      snapshot: snapshot,
      now: now,
      history: history,
      observers: observers
    )
    advanceFailureWindow(with: results.failedRuleIDs)
    applyNewQuarantines(for: results.failedRuleIDs)
    await dispatchActions(
      results.actionsByRule,
      tickID: snapshot.id,
      firedAt: now,
      observers: observers
    )
    await dispatchObserverSuggestions(
      from: observers,
      history: history,
      tickID: snapshot.id
    )
    recordTickLatency(startedAt: tickStartedAt, endedAt: clock.now())
    if let store {
      let liveTick = liveTickSnapshot()
      await MainActor.run {
        store.applySupervisorLiveTick(liveTick)
      }
    }
  }

  private struct TickResults {
    var actionsByRule: [(rule: any PolicyRule, actions: [PolicyAction])] = []
    var failedRuleIDs: Set<String> = []
  }

  private func evaluateRules(
    _ rules: [any PolicyRule],
    snapshot: SessionsSnapshot,
    now: Date,
    history: PolicyHistoryWindow,
    observers: [any PolicyObserver]
  ) async -> TickResults {
    let quarantinedSnapshot = quarantined
    let armedSnapshot = injectedFailures

    let timeout = ruleEvaluationTimeout
    return await withTaskGroup(of: (Int, SupervisorRuleEvaluation).self) { group in
      var scheduledRuleIDs: [String] = []
      for rule in rules where !quarantinedSnapshot.contains(rule.id) {
        guard await registry.isEnabled(ruleID: rule.id) else {
          continue
        }
        let index = scheduledRuleIDs.count
        scheduledRuleIDs.append(rule.id)
        let armed = armedSnapshot.contains(rule.id)
        let context = await makeContext(
          forRuleID: rule.id,
          now: now,
          history: history
        )
        group.addTask { [context] in
          (
            index,
            await Self.runRule(
              rule,
              snapshot: snapshot,
              context: context,
              armed: armed,
              timeout: timeout
            )
          )
        }
      }
      var evaluations = [SupervisorRuleEvaluation?](repeating: nil, count: scheduledRuleIDs.count)
      for await (index, evaluation) in group {
        evaluations[index] = evaluation
      }
      var results = TickResults()
      for evaluation in evaluations.compactMap(\.self) {
        if evaluation.failed {
          results.failedRuleIDs.insert(evaluation.ruleID)
        }
        for observer in observers {
          await observer.didEvaluate(rule: evaluation.rule, actions: evaluation.actions)
        }
        if !evaluation.actions.isEmpty {
          results.actionsByRule.append((evaluation.rule, evaluation.actions))
        }
      }
      return results
    }
  }

  private static func runRule(
    _ rule: any PolicyRule,
    snapshot: SessionsSnapshot,
    context: PolicyContext,
    armed: Bool,
    timeout: Duration
  ) async -> SupervisorRuleEvaluation {
    if armed {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.rule.failed rule=\(rule.id)"
      )
      return SupervisorRuleEvaluation(ruleID: rule.id, rule: rule, actions: [], failed: true)
    }
    let gate = SupervisorOneShotGate<SupervisorRuleEvaluation>()
    let evaluationTask = Task {
      let actions = await rule.evaluate(snapshot: snapshot, context: context)
      await gate.finish(
        SupervisorRuleEvaluation(ruleID: rule.id, rule: rule, actions: actions, failed: false)
      )
    }
    let timeoutTask = Task {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      evaluationTask.cancel()
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.rule.timeout rule=\(rule.id)"
      )
      await gate.finish(
        SupervisorRuleEvaluation(ruleID: rule.id, rule: rule, actions: [], failed: true)
      )
    }
    let evaluation = await gate.wait()
    timeoutTask.cancel()
    return evaluation
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
        HarnessMonitorLogger.supervisorError(
          "supervisor.rule.quarantined rule=\(ruleID) count=\(count)"
        )
      }
    }
  }

  private func dispatchActions(
    _ actionsByRule: [(rule: any PolicyRule, actions: [PolicyAction])],
    tickID: String,
    firedAt: Date,
    observers: [any PolicyObserver]
  ) async {
    for entry in actionsByRule {
      var dispatchedActions: [PolicyAction] = []
      for action in entry.actions {
        let behavior = await registry.defaultBehavior(
          for: entry.rule,
          actionKey: action.actionKey
        )
        let actionNow = clock.now()
        if shouldSuppress(action, behavior: behavior, at: actionNow) {
          HarnessMonitorLogger.supervisorTrace(
            "supervisor.action.suppressed key=\(action.actionKey)"
          )
          await executor.recordSuppressed(action, tickID: tickID)
          recordSuppressedAction(forRuleID: entry.rule.id, action: action, suppressedAt: actionNow)
          continue
        }
        let outcome = await dispatch(action, tickID: tickID, observers: observers)
        if outcome.recordsFiredAction {
          dispatchedActions.append(action)
        }
      }
      recordFiredActions(forRuleID: entry.rule.id, actions: dispatchedActions, firedAt: firedAt)
    }
    for ruleID in quarantined where wasQuarantinedThisTick(ruleID) {
      let decision = Self.makeQuarantineDecision(for: ruleID)
      let outcome = await dispatch(.queueDecision(decision), tickID: tickID, observers: observers)
      if outcome.recordsFiredAction {
        dispatchedQuarantineDecisions.insert(ruleID)
      }
    }
  }

  private func dispatchObserverSuggestions(
    from observers: [any PolicyObserver],
    history: PolicyHistoryWindow,
    tickID: String
  ) async {
    for observer in observers {
      let suggestions = await observer.proposeConfigSuggestion(history: history)
      for suggestion in suggestions {
        _ = await dispatch(.suggestConfigChange(suggestion), tickID: tickID, observers: observers)
      }
    }
  }

  private func wasQuarantinedThisTick(_ ruleID: String) -> Bool {
    quarantined.contains(ruleID) && !dispatchedQuarantineDecisions.contains(ruleID)
  }

  private func dispatch(
    _ action: PolicyAction,
    tickID: String,
    observers: [any PolicyObserver]
  ) async -> PolicyOutcome {
    let outcome = await executor.execute(action, tickID: tickID)
    for observer in observers {
      await observer.didExecute(action: action, outcome: outcome)
    }
    return outcome
  }

}
