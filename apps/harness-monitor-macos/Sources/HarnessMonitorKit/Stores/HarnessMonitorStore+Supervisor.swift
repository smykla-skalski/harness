import Foundation
import SwiftData

// MARK: - Supervisor stack holder

/// Holds all supervisor components as a single associated-object payload so stored properties
/// can be added to `HarnessMonitorStore` without modifying the main class file.
private final class SupervisorStack {
  let decisionStore: DecisionStore
  let registry: PolicyRegistry
  let executor: PolicyExecutor
  let service: SupervisorService
  let lifecycle: SupervisorLifecycle

  init(
    decisionStore: DecisionStore,
    registry: PolicyRegistry,
    executor: PolicyExecutor,
    service: SupervisorService,
    lifecycle: SupervisorLifecycle
  ) {
    self.decisionStore = decisionStore
    self.registry = registry
    self.executor = executor
    self.service = service
    self.lifecycle = lifecycle
  }
}

private enum SupervisorStackKey {
  // A UInt8 static gives a stable address for objc_setAssociatedObject.
  nonisolated(unsafe) static var key: UInt8 = 0
}

// MARK: - HarnessMonitorStore + Supervisor extension

extension HarnessMonitorStore {
  // MARK: - Private access helpers

  private var _stack: SupervisorStack? {
    get {
      objc_getAssociatedObject(self, &SupervisorStackKey.key) as? SupervisorStack
    }
    set {
      objc_setAssociatedObject(
        self,
        &SupervisorStackKey.key,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }

  // MARK: - Public API

  /// Boots the supervisor stack:
  /// 1. Creates an in-memory or container-backed `DecisionStore`.
  /// 2. Builds a `PolicyRegistry` with all built-in rules registered.
  /// 3. Creates a `PolicyExecutor` wired to the store's current daemon client.
  /// 4. Creates a `SupervisorService` with a 10-second tick interval.
  /// 5. Wires `supervisorToolbarSlice` to the decision stream.
  /// 6. Starts the service tick loop.
  /// 7. Arms the `NSBackgroundActivityScheduler` via `SupervisorLifecycle`.
  ///
  /// Idempotent: if the supervisor is already running, returns immediately.
  public func startSupervisor() async {
    guard _stack == nil else {
      HarnessMonitorLogger.supervisor.info("supervisor.start skipped — already running")
      return
    }

    HarnessMonitorLogger.supervisor.info("supervisor.start")

    let decisionStore: DecisionStore
    if let container = modelContext?.container {
      decisionStore = DecisionStore(container: container)
    } else {
      do {
        decisionStore = try DecisionStore.makeInMemory()
      } catch {
        HarnessMonitorLogger.supervisor.error(
          "supervisor.start failed to create DecisionStore: \(error.localizedDescription, privacy: .public)"
        )
        return
      }
    }

    let registry = PolicyRegistry()
    await buildDefaultRegistry(registry)
    await registry.applyOverrides(Self.loadPolicyOverrides(from: modelContext))

    let apiClient = StoreAPIClient(store: self)
    let auditWriter = NoOpSupervisorAuditWriter()
    let executor = PolicyExecutor(
      api: apiClient,
      decisions: decisionStore,
      audit: auditWriter
    )

    let service = SupervisorService(
      store: self,
      registry: registry,
      executor: executor,
      clock: nil,
      interval: SupervisorPreferencesDefaults.defaultIntervalSeconds
    )
    await service.setQuietHoursWindow(SupervisorPreferencesDefaults.quietHoursWindow())

    let lifecycle = SupervisorLifecycle(
      interval: SupervisorPreferencesDefaults.defaultIntervalSeconds,
      tolerance: SupervisorPreferencesDefaults.schedulerTolerance
    )
    lifecycle.onTick = { [weak service] in
      Task {
        await service?.runOneTick()
      }
    }

    let stack = SupervisorStack(
      decisionStore: decisionStore,
      registry: registry,
      executor: executor,
      service: service,
      lifecycle: lifecycle
    )
    _stack = stack

    supervisorToolbarSlice.start(decisions: decisionStore)

    await service.start()
    lifecycle.startBackgroundActivity()

    HarnessMonitorLogger.supervisor.info("supervisor.started")
  }

  /// Tears down the supervisor: stops the tick loop, invalidates the background scheduler,
  /// and stops the toolbar slice observer.
  public func stopSupervisor() async {
    guard let stack = _stack else {
      HarnessMonitorLogger.supervisor.info("supervisor.stop skipped — not running")
      return
    }
    _stack = nil

    stack.lifecycle.stopBackgroundActivity()
    await stack.service.stop()
    supervisorToolbarSlice.stop()

    HarnessMonitorLogger.supervisor.info("supervisor.stopped")
  }

  public func setSupervisorRunInBackgroundEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    guard let stack = _stack else {
      return
    }
    if enabled {
      stack.lifecycle.startBackgroundActivity()
    } else {
      stack.lifecycle.stopBackgroundActivity()
    }
  }

  public func setSupervisorQuietHoursWindow(_ window: SupervisorQuietHoursWindow?) {
    guard let service = _stack?.service else {
      return
    }
    Task {
      await self.applySupervisorQuietHoursWindow(window, service: service)
    }
  }

  public func refreshSupervisorPolicyOverrides() async {
    guard let registry = _stack?.registry else {
      return
    }
    await registry.applyOverrides(Self.loadPolicyOverrides(from: modelContext))
  }

  // MARK: - Test hooks

  /// Runs one supervisor tick inline. Only for tests — production code uses the tick loop.
  public func runSupervisorTickForTesting() async {
    guard let stack = _stack else {
      return
    }
    await stack.service.runOneTick()
  }

  /// Inserts a `DecisionDraft` directly into the decision store. Only for tests.
  public func insertDecisionForTesting(_ draft: DecisionDraft) async throws {
    guard let stack = _stack else {
      return
    }
    try await stack.decisionStore.insert(draft)
  }

  public func isSupervisorBackgroundActivityScheduledForTesting() -> Bool {
    _stack?.lifecycle.isBackgroundActivityScheduled ?? false
  }

  public func isSupervisorAutoActionSuppressedForTesting(at date: Date) async -> Bool {
    guard let service = _stack?.service else {
      return false
    }
    return await service.isAutoActionSuppressed(at: date)
  }

  public func applySupervisorQuietHoursWindowForTesting(
    _ window: SupervisorQuietHoursWindow?
  ) async {
    guard let service = _stack?.service else {
      return
    }
    await applySupervisorQuietHoursWindow(window, service: service)
  }

  // MARK: - Private helpers

  private func buildDefaultRegistry(_ registry: PolicyRegistry) async {
    for rule in HarnessMonitorSupervisorRuleCatalog.makeRules() {
      await registry.register(rule)
    }
    for observer in HarnessMonitorSupervisorRuleCatalog.makeObservers() {
      await registry.registerObserver(observer)
    }
  }

  private func applySupervisorQuietHoursWindow(
    _ window: SupervisorQuietHoursWindow?,
    service: SupervisorService
  ) async {
    await service.setQuietHoursWindow(window)
  }

  private static func loadPolicyOverrides(
    from modelContext: ModelContext?
  ) -> [PolicyConfigOverride] {
    guard let modelContext else {
      return []
    }

    do {
      let descriptor = FetchDescriptor<PolicyConfigRow>(
        sortBy: [SortDescriptor(\.ruleID)]
      )
      return try modelContext.fetch(descriptor).map { row in
        PolicyConfigOverride(
          ruleID: row.ruleID,
          enabled: row.enabled,
          defaultBehavior: RuleDefaultBehavior(rawValue: row.defaultBehaviorRaw) ?? .cautious,
          parameters: Self.decodeParameters(from: row.parametersJSON)
        )
      }
    } catch {
      HarnessMonitorLogger.supervisor.warning(
        "supervisor.policy_config_load_failed error=\(String(describing: error), privacy: .public)"
      )
      return []
    }
  }

  private static func decodeParameters(from json: String) -> [String: String] {
    guard
      let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    var parameters: [String: String] = [:]
    for (key, value) in object {
      switch value {
      case let string as String:
        parameters[key] = string
      case let number as NSNumber:
        parameters[key] = number.stringValue
      default:
        continue
      }
    }
    return parameters
  }
}

// MARK: - StoreAPIClient

/// Thin adapter that wraps `HarnessMonitorStore` and routes supervisor API calls to whatever
/// daemon client is currently active. If no client is connected the call is a no-op.
private struct StoreAPIClient: SupervisorAPIClient {
  /// Weak via `unowned` would be preferable but `unowned` on non-class-constrained protocol is
  /// not supported; capture the store strongly and tolerate the retain cycle since the store
  /// owns the stack (and therefore this client) via the associated object.
  private let store: HarnessMonitorStore

  init(store: HarnessMonitorStore) {
    self.store = store
  }

  func nudgeAgent(agentID: String, input: String) async throws {
    guard let client = await MainActor.run(body: { store.client }) else { return }
    let request = AgentTuiInputRequest(input: .text(input))
    _ = try await client.sendManagedAgentInput(agentID: agentID, request: request)
  }

  func assignTask(taskID: String, agentID: String) async throws {
    // Task assignment is not currently exposed directly on the store client; no-op for now.
    HarnessMonitorLogger.supervisor.debug(
      "supervisor.assign_task taskID=\(taskID, privacy: .public) agentID=\(agentID, privacy: .public)"
    )
  }

  func dropTask(taskID: String, reason: String) async throws {
    HarnessMonitorLogger.supervisor.debug(
      "supervisor.drop_task taskID=\(taskID, privacy: .public) reason=\(reason, privacy: .public)"
    )
  }

  func postNotification(ruleID: String, severity: DecisionSeverity, summary: String) async {
    HarnessMonitorLogger.supervisor.info(
      """
      supervisor.notify ruleID=\(ruleID, privacy: .public)
      severity=\(severity.rawValue, privacy: .public)
      summary=\(summary, privacy: .public)
      """
    )
  }
}

// MARK: - No-op audit writer (production wiring; real writer is Phase 2 worker 16)

private struct NoOpSupervisorAuditWriter: SupervisorAuditWriter {
  func append(_ record: SupervisorAuditRecord) async {}
}
