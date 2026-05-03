import Foundation
import SwiftData

final class SupervisorStack {
  let decisionStore: DecisionStore
  let registry: PolicyRegistry
  let executor: PolicyExecutor
  let service: SupervisorService
  let lifecycle: SupervisorLifecycle
  let auditRetention: SupervisorAuditRetention?
  let relayTask: Task<Void, Never>
  // Identity-stable handler reused for the lifetime of this stack so views that
  // accept the handler never see a fresh existential per parent body eval.
  private var cachedActionHandler: StoreDecisionActionHandler?

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

  @MainActor
  func actionHandler(for store: HarnessMonitorStore) -> StoreDecisionActionHandler {
    if let cached = cachedActionHandler {
      return cached
    }
    let handler = StoreDecisionActionHandler(store: store, decisions: decisionStore)
    cachedActionHandler = handler
    return handler
  }
}

final class SupervisorBindings {
  weak var notificationController: HarnessMonitorUserNotificationController?
  var pendingDecisionsBadgeSync: (@MainActor (Int) -> Void)?
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

private enum SupervisorNullActionHandlerKey {
  nonisolated(unsafe) static var key: UInt8 = 0
}

extension HarnessMonitorStore {
  var supervisorStack: SupervisorStack? {
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

  var supervisorStartTask: Task<Void, Never>? {
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

  fileprivate var cachedNullActionHandler: NullDecisionActionHandler? {
    get {
      objc_getAssociatedObject(self, &SupervisorNullActionHandlerKey.key)
        as? NullDecisionActionHandler
    }
    set {
      objc_setAssociatedObject(
        self,
        &SupervisorNullActionHandlerKey.key,
        newValue,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
      )
    }
  }

  public var supervisorDecisionStore: DecisionStore? {
    supervisorStack?.decisionStore
  }

  public func requestObserverFocusInDecisions() {
    supervisorObserverFocusTick &+= 1
  }

  public func requestPrimaryDecisionActionFocus(decisionID: String) {
    supervisorPrimaryActionFocusDecisionID = decisionID
    supervisorPrimaryActionFocusRequestTick &+= 1
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

  public func bindPendingDecisionsBadgeSync(
    _ sync: @escaping @MainActor (Int) -> Void
  ) {
    supervisorBindings.pendingDecisionsBadgeSync = sync
  }

  public func supervisorDecisionActionHandler() -> any DecisionActionHandler {
    if let stack = supervisorStack {
      return stack.actionHandler(for: self)
    }
    if let cached = cachedNullActionHandler {
      return cached
    }
    let handler = NullDecisionActionHandler()
    cachedNullActionHandler = handler
    return handler
  }

  public func startSupervisor() async {
    guard supervisorStack == nil else {
      HarnessMonitorLogger.supervisorTrace("supervisor.start skipped — already running")
      return
    }

    if let startTask = supervisorStartTask {
      await startTask.value
      return
    }

    let startTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.performSupervisorStartup()
    }
    supervisorStartTask = startTask
    await startTask.value
  }

  public func stopSupervisor() async {
    guard let stack = supervisorStack else {
      HarnessMonitorLogger.supervisorTrace("supervisor.stop skipped — not running")
      return
    }
    supervisorStack = nil

    stack.relayTask.cancel()
    stack.lifecycle.stopBackgroundActivity()
    stack.auditRetention?.stopBackgroundCompaction()
    await stack.service.stop()
    supervisorToolbarSlice.stop()
    supervisorOpenDecisions = []
    supervisorSelectedDecisionID = nil
    supervisorPrimaryActionFocusDecisionID = nil
    supervisorBindings.pendingDecisionsBadgeSync?(0)
    if let controller = supervisorBindings.notificationController {
      await controller.resetBadge()
    }
    supervisorDecisionRefreshTick &+= 1

    HarnessMonitorLogger.supervisorTrace("supervisor.stopped")
  }

  public func setSupervisorRunInBackgroundEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    guard let stack = supervisorStack else {
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
    guard let service = supervisorStack?.service else {
      return
    }
    Task {
      await self.applySupervisorQuietHoursWindow(window, service: service)
    }
  }

  public func refreshSupervisorPolicyOverrides() async {
    guard let registry = supervisorStack?.registry else {
      return
    }
    await registry.applyOverrides(Self.loadPolicyOverrides(from: modelContext))
  }

  public func supervisorLiveTickSnapshot() async -> DecisionLiveTickSnapshot {
    guard let service = supervisorStack?.service else {
      return .placeholder
    }
    return await service.liveTickSnapshot()
  }

  public func withSupervisorAutoActionsSuppressed<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async rethrows -> Result {
    guard let service = supervisorStack?.service else {
      return try await operation()
    }
    return try await service.suppressAutoActions(during: operation)
  }

  public func runSupervisorTickForTesting() async {
    if supervisorStack == nil {
      await startSupervisor()
    }
    guard let stack = supervisorStack else {
      return
    }
    await stack.service.runOneTick()
  }

  public func insertDecisionForTesting(_ draft: DecisionDraft) async throws {
    guard let stack = supervisorStack else {
      return
    }
    try await stack.decisionStore.insert(draft)
  }

  public func isSupervisorBackgroundActivityScheduledForTesting() -> Bool {
    supervisorStack?.lifecycle.isBackgroundActivityScheduled ?? false
  }

  public func isSupervisorAuditRetentionScheduledForTesting() -> Bool {
    supervisorStack?.auditRetention?.isBackgroundActivityScheduled ?? false
  }

  public func isSupervisorAutoActionSuppressedForTesting(at date: Date) async -> Bool {
    guard let service = supervisorStack?.service else {
      return false
    }
    return await service.isAutoActionSuppressed(at: date)
  }

  public func applySupervisorQuietHoursWindowForTesting(
    _ window: SupervisorQuietHoursWindow?
  ) async {
    guard let service = supervisorStack?.service else {
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
