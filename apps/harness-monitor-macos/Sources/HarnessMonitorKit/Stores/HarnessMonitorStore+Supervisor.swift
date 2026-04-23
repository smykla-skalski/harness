import Foundation
import SwiftData

private final class SupervisorStack {
  let decisionStore: DecisionStore
  let registry: PolicyRegistry
  let executor: PolicyExecutor
  let service: SupervisorService
  let lifecycle: SupervisorLifecycle
  let auditRetention: SupervisorAuditRetention?
  let relayTask: Task<Void, Never>

  init(
    decisionStore: DecisionStore,
    registry: PolicyRegistry,
    executor: PolicyExecutor,
    service: SupervisorService,
    lifecycle: SupervisorLifecycle,
    auditRetention: SupervisorAuditRetention?,
    relayTask: Task<Void, Never>
  ) {
    self.decisionStore = decisionStore
    self.registry = registry
    self.executor = executor
    self.service = service
    self.lifecycle = lifecycle
    self.auditRetention = auditRetention
    self.relayTask = relayTask
  }
}

final class SupervisorBindings {
  weak var notificationController: HarnessMonitorUserNotificationController?
}

private enum SupervisorStackKey {
  nonisolated(unsafe) static var key: UInt8 = 0
}

private enum SupervisorBindingsKey {
  nonisolated(unsafe) static var key: UInt8 = 0
}

private enum SupervisorStartTaskKey {
  nonisolated(unsafe) static var key: UInt8 = 0
}

extension HarnessMonitorStore {
  fileprivate var _stack: SupervisorStack? {
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

  var supervisorBindings: SupervisorBindings {
    if let existing = objc_getAssociatedObject(self, &SupervisorBindingsKey.key)
      as? SupervisorBindings
    {
      return existing
    }
    let created = SupervisorBindings()
    objc_setAssociatedObject(
      self,
      &SupervisorBindingsKey.key,
      created,
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
    return created
  }

  fileprivate var _supervisorStartTask: Task<Void, Never>? {
    get {
      objc_getAssociatedObject(self, &SupervisorStartTaskKey.key) as? Task<Void, Never>
    }
    set {
      objc_setAssociatedObject(
        self,
        &SupervisorStartTaskKey.key,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }

  public var supervisorDecisionStore: DecisionStore? {
    _stack?.decisionStore
  }

  public var isSupervisorRunInBackgroundEnabled: Bool {
    let storedValue =
      UserDefaults.standard.object(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      ) as? Bool
    return storedValue ?? SupervisorPreferencesDefaults.runInBackgroundDefault
  }

  public func bindSupervisorNotifications(_ controller: HarnessMonitorUserNotificationController) {
    supervisorBindings.notificationController = controller
    controller.attachResolveHandler { [weak self] decisionID, outcome in
      guard let self else {
        return
      }
      await MainActor.run {
        self.enqueueNotificationResolution(decisionID: decisionID, outcome: outcome)
      }
    }
  }

  public func supervisorDecisionActionHandler() -> any DecisionActionHandler {
    guard let decisionStore = _stack?.decisionStore else {
      return NullDecisionActionHandler()
    }
    return StoreDecisionActionHandler(store: self, decisions: decisionStore)
  }

  public func startSupervisor() async {
    guard _stack == nil else {
      HarnessMonitorLogger.supervisorInfo("supervisor.start skipped — already running")
      return
    }

    if let startTask = _supervisorStartTask {
      await startTask.value
      return
    }

    let startTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.performSupervisorStartup()
    }
    _supervisorStartTask = startTask
    await startTask.value
  }

  private func performSupervisorStartup() async {
    defer { _supervisorStartTask = nil }

    guard _stack == nil else {
      HarnessMonitorLogger.supervisorInfo("supervisor.start skipped — already running")
      return
    }

    HarnessMonitorLogger.supervisorInfo("supervisor.start")

    let decisionStore: DecisionStore
    if let container = modelContext?.container {
      decisionStore = DecisionStore(container: container)
    } else {
      do {
        decisionStore = try DecisionStore.makeInMemory()
      } catch {
        HarnessMonitorLogger.supervisorError(
          "supervisor.start failed to create DecisionStore: \(error.localizedDescription)"
        )
        return
      }
    }

    let registry = PolicyRegistry()
    await registry.registerDefaults()
    await registry.applyOverrides(Self.loadPolicyOverrides(from: modelContext))

    let apiClient = StoreAPIClient(store: self)
    let auditWriter: any SupervisorAuditWriter
    let auditRetention: SupervisorAuditRetention?
    if let container = modelContext?.container {
      auditWriter = SwiftDataSupervisorAuditWriter(container: container)
      auditRetention = SupervisorAuditRetention(container: container)
    } else {
      auditWriter = NoOpSupervisorAuditWriter()
      auditRetention = nil
    }

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
      await service?.runOneTick()
    }

    do {
      try await seedSupervisorDecisionsIfNeeded(decisionStore)
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.seed_decisions_failed error=\(String(describing: error))"
      )
    }

    let relayTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.refreshSupervisorDecisionSurfaces(decisions: decisionStore)
      for await _ in decisionStore.events {
        guard !Task.isCancelled else {
          return
        }
        await self.refreshSupervisorDecisionSurfaces(decisions: decisionStore)
      }
    }

    let stack = SupervisorStack(
      decisionStore: decisionStore,
      registry: registry,
      executor: executor,
      service: service,
      lifecycle: lifecycle,
      auditRetention: auditRetention,
      relayTask: relayTask
    )
    _stack = stack

    await service.start()
    lifecycle.startBackgroundActivity()
    auditRetention?.startBackgroundCompaction()

    HarnessMonitorLogger.supervisorInfo("supervisor.started")
  }

  public func stopSupervisor() async {
    guard let stack = _stack else {
      HarnessMonitorLogger.supervisorInfo("supervisor.stop skipped — not running")
      return
    }
    _stack = nil

    stack.relayTask.cancel()
    stack.lifecycle.stopBackgroundActivity()
    stack.auditRetention?.stopBackgroundCompaction()
    await stack.service.stop()
    supervisorToolbarSlice.stop()
    supervisorOpenDecisions = []
    supervisorSelectedDecisionID = nil
    supervisorDecisionRefreshTick &+= 1

    HarnessMonitorLogger.supervisorInfo("supervisor.stopped")
  }

  public func setSupervisorRunInBackgroundEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    guard let stack = _stack else {
      return
    }
    if enabled {
      stack.lifecycle.startBackgroundActivity()
      stack.auditRetention?.startBackgroundCompaction()
    } else {
      stack.lifecycle.stopBackgroundActivity()
      stack.auditRetention?.stopBackgroundCompaction()
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

  public func supervisorLiveTickSnapshot() async -> DecisionLiveTickSnapshot {
    guard let service = _stack?.service else {
      return .placeholder
    }
    return await service.liveTickSnapshot()
  }

  public func withSupervisorAutoActionsSuppressed<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async rethrows -> Result {
    guard let service = _stack?.service else {
      return try await operation()
    }
    return try await service.suppressAutoActions(during: operation)
  }

  public func runSupervisorTickForTesting() async {
    if _stack == nil {
      await startSupervisor()
    }
    guard let stack = _stack else {
      return
    }
    await stack.service.runOneTick()
  }

  public func insertDecisionForTesting(_ draft: DecisionDraft) async throws {
    guard let stack = _stack else {
      return
    }
    try await stack.decisionStore.insert(draft)
  }

  public func isSupervisorBackgroundActivityScheduledForTesting() -> Bool {
    _stack?.lifecycle.isBackgroundActivityScheduled ?? false
  }

  public func isSupervisorAuditRetentionScheduledForTesting() -> Bool {
    _stack?.auditRetention?.isBackgroundActivityScheduled ?? false
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

  private func applySupervisorQuietHoursWindow(
    _ window: SupervisorQuietHoursWindow?,
    service: SupervisorService
  ) async {
    await service.setQuietHoursWindow(window)
  }

  private func refreshSupervisorDecisionSurfaces(decisions: DecisionStore) async {
    let openDecisions = (try? await decisions.openDecisions()) ?? []
    var counts: [DecisionSeverity: Int] = [:]
    for decision in openDecisions {
      guard let severity = DecisionSeverity(rawValue: decision.severityRaw) else {
        continue
      }
      counts[severity, default: 0] += 1
    }
    supervisorOpenDecisions = openDecisions
    supervisorToolbarSlice.refresh(counts: counts)
    supervisorDecisionRefreshTick &+= 1
  }

  private func enqueueNotificationResolution(
    decisionID: String,
    outcome: DecisionOutcome
  ) {
    Task { @MainActor in
      let handler = self.supervisorDecisionActionHandler()
      await handler.resolve(decisionID: decisionID, outcome: outcome)
    }
  }

}
