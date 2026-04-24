import Foundation
import OpenTelemetryApi
import SwiftData

public actor SupervisorService {
  private static let quarantineErrorThreshold = 5
  private static let quarantineWindowTicks = 10
  private let store: HarnessMonitorStore?
  private let registry: PolicyRegistry
  private let executor: PolicyExecutor
  private let clock: any SupervisorClock
  private let interval: TimeInterval

  private var tickTask: Task<Void, Never>?
  private var running = false, tickInProgress = false
  private var autoActionsSuppressed = false
  private var quietHoursWindow: SupervisorQuietHoursWindow?

  private var ruleFailureWindow: [[String: Bool]] = []
  private var quarantined: Set<String> = []
  private var injectedFailures: Set<String> = []
  private var dispatchedQuarantineDecisions: Set<String> = []
  private var ruleLastFiredAt: [String: Date] = [:]
  private var ruleRecentActionKeys: [String: Set<String>] = [:]
  private var tickLatencySamplesMs: [Double] = []
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
    HarnessMonitorLogger.supervisorInfo(
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
    if !tickInProgress {
      tickTask?.cancel()
    }
    _ = await tickTask?.value
    tickTask = nil
    HarnessMonitorLogger.supervisorInfo("supervisor.stop")
  }

  public func runOneTick() async { await tickBody() }

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

  public func awaitCurrentTick() async { await Task.yield() }

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
        try await clock.sleep(for: .seconds(Int(interval)))
      } catch {
        return
      }
      guard running && !Task.isCancelled else { return }
      tickInProgress = true
      defer { tickInProgress = false }
      await tickBody()
    }
  }

  private func tickBody() async {
    let tickStartedAt = Date()
    let tracer = SupervisorTelemetry.tracer()
    let span = tracer.spanBuilder(spanName: SupervisorTelemetry.tickSpanName).startSpan()
    defer { span.end() }

    let now = clock.now()
    let snapshot = await buildSnapshot(now: now)
    HarnessMonitorLogger.supervisorDebug(
      "supervisor.tick snapshot=\(snapshot.id)"
    )

    let rules = await registry.allRules
    let observers = await registry.observerList
    lastSnapshotID = snapshot.id
    lastObserverCount = observers.count
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
    await dispatchActions(
      results.actionsByRule,
      tickID: snapshot.id,
      firedAt: now,
      observers: observers
    )
    recordTickLatency(startedAt: tickStartedAt)
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
    let history = await historyWindow()
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
    _ actionsByRule: [(ruleID: String, actions: [PolicyAction])],
    tickID: String,
    firedAt: Date,
    observers: [any PolicyObserver]
  ) async {
    for entry in actionsByRule {
      recordFiredActions(forRuleID: entry.ruleID, actions: entry.actions, firedAt: firedAt)
      for action in entry.actions {
        if shouldSuppress(action, at: clock.now()) {
          HarnessMonitorLogger.supervisorTrace(
            "supervisor.action.suppressed key=\(action.actionKey)"
          )
          continue
        }
        await dispatch(action, tickID: tickID, observers: observers)
      }
    }
    for ruleID in quarantined where wasQuarantinedThisTick(ruleID) {
      let decision = Self.makeQuarantineDecision(for: ruleID)
      await dispatch(.queueDecision(decision), tickID: tickID, observers: observers)
      dispatchedQuarantineDecisions.insert(ruleID)
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

  private func shouldSuppress(_ action: PolicyAction, at now: Date) -> Bool {
    action.isAutomaticSideEffect && suppressionActive(at: now)
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
      recentActionKeys: ruleRecentActionKeys[ruleID] ?? [],
      parameters: await registry.parameters(forRule: ruleID),
      history: history
    )
  }

  private func recordFiredActions(
    forRuleID ruleID: String,
    actions: [PolicyAction],
    firedAt: Date
  ) {
    ruleRecentActionKeys[ruleID] = Set(actions.map(\.actionKey))
    guard !actions.isEmpty else {
      return
    }
    ruleLastFiredAt[ruleID] = firedAt
  }

  private func historyWindow() async -> PolicyHistoryWindow {
    guard let store else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
    return await MainActor.run {
      Self.historyWindow(from: store.modelContext)
    }
  }

  @MainActor
  private static func historyWindow(from context: ModelContext?) -> PolicyHistoryWindow {
    guard let context else {
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }

    do {
      var eventDescriptor = FetchDescriptor<SupervisorEvent>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      eventDescriptor.fetchLimit = 64
      let recentEvents = try context.fetch(eventDescriptor).map {
        SupervisorEventSummary(
          id: $0.id,
          kind: $0.kind,
          ruleID: $0.ruleID,
          createdAt: $0.createdAt
        )
      }

      var decisionDescriptor = FetchDescriptor<Decision>(
        sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
      )
      decisionDescriptor.fetchLimit = 64
      let decisions = try context.fetch(decisionDescriptor)
      let recentDecisions: [DecisionSummary] = decisions.compactMap { decision in
        guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else {
          return nil
        }
        return DecisionSummary(
          id: decision.id,
          ruleID: decision.ruleID,
          severity: severity,
          createdAt: decision.createdAt
        )
      }

      return PolicyHistoryWindow(
        recentEvents: recentEvents,
        recentDecisions: recentDecisions
      )
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.history_load_failed error=\(String(describing: error))"
      )
      return PolicyHistoryWindow(recentEvents: [], recentDecisions: [])
    }
  }

  private func recordTickLatency(startedAt: Date) {
    tickLatencySamplesMs.append(Date().timeIntervalSince(startedAt) * 1_000)
    if tickLatencySamplesMs.count > 32 {
      tickLatencySamplesMs.removeFirst(tickLatencySamplesMs.count - 32)
    }
  }

  private func percentile(_ value: Double) -> Double {
    guard !tickLatencySamplesMs.isEmpty else {
      return 0
    }
    let sorted = tickLatencySamplesMs.sorted()
    let lastIndex = sorted.count - 1
    let index = Int((Double(lastIndex) * value).rounded(.down))
    return sorted[max(0, min(lastIndex, index))]
  }
}
