import Foundation
import SwiftData

#if HARNESS_FEATURE_OTEL
  import OpenTelemetryApi
#endif

public actor SupervisorService {
  private static let quarantineErrorThreshold = 5
  private static let quarantineWindowTicks = 10
  let store: HarnessMonitorStore?
  private let registry: PolicyRegistry
  private let executor: PolicyExecutor
  private let clock: any SupervisorClock
  private let interval: TimeInterval

  private var tickTask: Task<Void, Never>?
  private var running = false, tickInProgress = false
  private var tickWaiters: [CheckedContinuation<Void, Never>] = []
  private var autoActionsSuppressed = false
  private var quietHoursWindow: SupervisorQuietHoursWindow?

  private var ruleFailureWindow: [[String: Bool]] = []
  private var quarantined: Set<String> = []
  private var injectedFailures: Set<String> = []
  private var dispatchedQuarantineDecisions: Set<String> = []
  private var ruleLastFiredAt: [String: Date] = [:]
  private var ruleRecentActionKeys: [String: Set<String>] = [:]
  private var ruleRecentSuppressedActionKeys: [String: Set<String>] = [:]
  var tickLatencySamplesMs: [Double] = []
  private var lastSnapshotID: String?
  private var lastObserverCount = 0

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
    HarnessMonitorLogger.supervisorTrace(
      "supervisor.start interval=\(self.interval)"
    )
    tickTask = Task { [weak self] in
      guard let self else { return }
      await self.runLoop()
    }
  }

  public func stop() async {
    guard running else { return }
    running = false
    tickTask?.cancel()
    await awaitCurrentTick()
    _ = await tickTask?.value
    tickTask = nil
    HarnessMonitorLogger.supervisorTrace("supervisor.stop")
  }

  public func runOneTick() async { await runTickSerialized() }

  public func suppressAutoActions<Result>(
    during operation: @Sendable () async throws -> Result
  ) async rethrows -> Result {
    autoActionsSuppressed = true
    defer { autoActionsSuppressed = false }
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

  private func runLoop() async {
    while running && !Task.isCancelled {
      do {
        try await clock.sleep(for: Self.sleepDuration(for: interval))
      } catch {
        return
      }
      guard running && !Task.isCancelled else { return }
      await runTickSerialized()
    }
  }

  private func runTickSerialized() async {
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

  private static func sleepDuration(for interval: TimeInterval) -> Duration {
    guard interval.isFinite, interval > 0 else {
      return .milliseconds(1)
    }
    let milliseconds = min(Double(Int64.max), (interval * 1_000).rounded(.up))
    return .milliseconds(Int64(max(1.0, milliseconds)))
  }

  private func tickBody() async {
    let tickStartedAt = Date()
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
    let history = await historyWindow()
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
    recordTickLatency(startedAt: tickStartedAt)
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

    return await withTaskGroup(of: RuleEvaluation.self) { group in
      for rule in rules where !quarantinedSnapshot.contains(rule.id) {
        guard await registry.isEnabled(ruleID: rule.id) else {
          continue
        }
        let armed = armedSnapshot.contains(rule.id)
        let context = await makeContext(
          forRuleID: rule.id,
          now: now,
          history: history
        )
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
          results.actionsByRule.append((evaluation.rule, evaluation.actions))
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
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.rule.failed rule=\(rule.id)"
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
        if shouldSuppress(action, behavior: behavior, at: clock.now()) {
          HarnessMonitorLogger.supervisorTrace(
            "supervisor.action.suppressed key=\(action.actionKey)"
          )
          await executor.recordSuppressed(action, tickID: tickID)
          recordSuppressedAction(forRuleID: entry.rule.id, action: action)
          continue
        }
        await dispatch(action, tickID: tickID, observers: observers)
        dispatchedActions.append(action)
      }
      recordFiredActions(forRuleID: entry.rule.id, actions: dispatchedActions, firedAt: firedAt)
    }
    for ruleID in quarantined where wasQuarantinedThisTick(ruleID) {
      let decision = Self.makeQuarantineDecision(for: ruleID)
      await dispatch(.queueDecision(decision), tickID: tickID, observers: observers)
      dispatchedQuarantineDecisions.insert(ruleID)
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
        await dispatch(.suggestConfigChange(suggestion), tickID: tickID, observers: observers)
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
  ) async {
    let outcome = await executor.execute(action, tickID: tickID)
    for observer in observers {
      await observer.didExecute(action: action, outcome: outcome)
    }
  }

  private func buildSnapshot(now: Date) async -> SessionsSnapshot {
    if let store {
      return await SessionsSnapshot.build(from: store, now: now)
    }
    return SessionsSnapshot(
      id: UUID().uuidString,
      createdAt: now,
      hash: "",
      sessions: [],
      connection: ConnectionSnapshot(kind: "disconnected", lastMessageAt: nil, reconnectAttempt: 0)
    )
  }

  private func shouldSuppress(
    _ action: PolicyAction,
    behavior: RuleDefaultBehavior,
    at now: Date
  ) -> Bool {
    guard action.isAutomaticSideEffect else {
      return false
    }
    return behavior == .cautious || suppressionActive(at: now)
  }

  private func suppressionActive(at now: Date) -> Bool {
    if autoActionsSuppressed {
      return true
    }
    return quietHoursWindow?.contains(now) == true
  }

  private func makeContext(
    forRuleID ruleID: String,
    now: Date,
    history: PolicyHistoryWindow
  ) async -> PolicyContext {
    PolicyContext(
      now: now,
      lastFiredAt: ruleLastFiredAt[ruleID],
      recentActionKeys: recentActionKeys(forRuleID: ruleID, at: now),
      parameters: await registry.parameters(forRule: ruleID),
      history: history
    )
  }

  private func recentActionKeys(forRuleID ruleID: String, at now: Date) -> Set<String> {
    var actionKeys = ruleRecentActionKeys[ruleID] ?? []
    if suppressionActive(at: now) {
      actionKeys.formUnion(ruleRecentSuppressedActionKeys[ruleID] ?? [])
    }
    return actionKeys
  }

  private func recordSuppressedAction(forRuleID ruleID: String, action: PolicyAction) {
    ruleRecentSuppressedActionKeys[ruleID, default: []].insert(action.actionKey)
  }

  private func recordFiredActions(
    forRuleID ruleID: String,
    actions: [PolicyAction],
    firedAt: Date
  ) {
    guard !actions.isEmpty else {
      return
    }
    ruleRecentActionKeys[ruleID] = Set(actions.map(\.actionKey))
    ruleLastFiredAt[ruleID] = firedAt
  }

}
