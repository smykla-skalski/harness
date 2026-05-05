import Foundation

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

  deinit {
    let serviceToStop = service
    relayTask.cancel()
    lifecycle.stopBackgroundActivity()
    auditRetention?.stopBackgroundCompaction()
    Task { await serviceToStop.stop() }
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
