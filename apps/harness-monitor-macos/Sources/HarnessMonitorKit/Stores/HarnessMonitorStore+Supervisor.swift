import Foundation

extension HarnessMonitorStore {
  public var supervisorDecisionStore: DecisionStore? {
    supervisorStack?.decisionStore
  }

  public var canRequestSupervisorCheckNow: Bool {
    supervisorRuntimeState != .starting && supervisorRuntimeState != .stopping
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
        forKey: SupervisorSettingsDefaults.runInBackgroundKey
      ) as? Bool
    return storedValue ?? SupervisorSettingsDefaults.runInBackgroundDefault
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
    if let stopTask = supervisorStopTask {
      await stopTask.value
    }

    guard supervisorStack == nil else {
      setSupervisorRuntimeState(.running)
      HarnessMonitorLogger.supervisorTrace("supervisor.start skipped — already running")
      return
    }

    if let startTask = supervisorStartTask {
      setSupervisorRuntimeState(.starting)
      await startTask.value
      return
    }

    setSupervisorRuntimeState(.starting)
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
    if let stopTask = supervisorStopTask {
      await stopTask.value
      return
    }

    if supervisorStack == nil, let startTask = supervisorStartTask {
      setSupervisorRuntimeState(.stopping)
      await startTask.value
    }
    guard let stack = supervisorStack else {
      setSupervisorRuntimeState(.stopped)
      HarnessMonitorLogger.supervisorTrace("supervisor.stop skipped — not running")
      return
    }

    setSupervisorRuntimeState(.stopping)
    let stopTask = Task { @MainActor [weak self] in
      guard let self else {
        return
      }
      await self.performSupervisorShutdown(stack)
    }
    supervisorStopTask = stopTask
    await stopTask.value
  }

  private func performSupervisorShutdown(_ stack: SupervisorStack) async {
    defer {
      supervisorStopTask = nil
      setSupervisorRuntimeState(.stopped)
      HarnessMonitorLogger.supervisorTrace("supervisor.stopped")
    }

    stopAcpPermissionDecisionProcessing()
    if supervisorStack === stack {
      supervisorStack = nil
    }

    stack.relayTask.cancel()
    supervisorTickTrigger.cancel()
    stack.lifecycle.stopBackgroundActivity()
    stack.auditRetention?.stopBackgroundCompaction()
    await stack.service.stop()
    supervisorToolbarSlice.stop()
    supervisorOpenDecisions = []
    supervisorSelectedDecisionID = nil
    supervisorPrimaryActionFocusDecisionID = nil
    resetSupervisorLiveTick()
    supervisorBindings.pendingDecisionsBadgeSync?(0)
    if let controller = supervisorBindings.notificationController {
      await controller.resetBadge()
    }
    supervisorDecisionRefreshTick &+= 1
  }

  public func setSupervisorRunInBackgroundEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: SupervisorSettingsDefaults.runInBackgroundKey)
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

  public func requestSupervisorCheckNow() async {
    guard canRequestSupervisorCheckNow else {
      return
    }
    await runSupervisorTickNow()
  }

  public func supervisorLiveTickSnapshot() async -> DecisionLiveTickSnapshot {
    supervisorLiveTick
  }

  public func withSupervisorAutoActionsSuppressed<Result: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Result
  ) async rethrows -> Result {
    guard let service = supervisorStack?.service else {
      return try await operation()
    }
    return try await service.suppressAutoActions(during: operation)
  }

  func runSupervisorTickNow() async {
    if supervisorStack == nil {
      await startSupervisor()
    }
    guard let stack = supervisorStack else {
      return
    }
    await stack.service.runOneTick()
  }

  func scheduleSupervisorTick(reason: String) {
    guard supervisorStack != nil else {
      return
    }
    let trigger = supervisorTickTrigger
    trigger.pending = true
    trigger.requestCount &+= 1
    trigger.latestReason = reason
    guard trigger.task == nil else {
      return
    }
    trigger.task = Task { @MainActor [weak self, weak trigger] in
      defer {
        if let trigger {
          let pendingReason = trigger.latestReason
          let shouldRearm = trigger.pending && !Task.isCancelled
          trigger.task = nil
          if shouldRearm, let self {
            self.scheduleSupervisorTick(reason: pendingReason ?? reason)
          }
        }
      }
      while trigger?.pending == true {
        let tickReason = trigger?.latestReason ?? reason
        trigger?.pending = false
        trigger?.latestReason = nil
        await Task.yield()
        guard !Task.isCancelled, let self else {
          return
        }
        if let trigger {
          trigger.drainCount &+= 1
        }
        HarnessMonitorLogger.supervisorTrace("supervisor.tick.requested reason=\(tickReason)")
        await self.runSupervisorTickNow()
      }
    }
  }

  public func runSupervisorTickForTesting() async {
    await runSupervisorTickNow()
  }

  public func supervisorScheduledTickCountsForTesting() -> (requests: Int, drains: Int) {
    let trigger = supervisorTickTrigger
    return (trigger.requestCount, trigger.drainCount)
  }

  public func insertDecisionForTesting(_ draft: DecisionDraft) async throws {
    guard let stack = supervisorStack else {
      return
    }
    try await stack.decisionStore.insert(draft)
  }

  func applySupervisorLiveTick(_ snapshot: DecisionLiveTickSnapshot) {
    guard supervisorLiveTick != snapshot else {
      return
    }
    supervisorLiveTick = snapshot
    supervisorLiveTickRefreshTick &+= 1
  }

  func resetSupervisorLiveTick() {
    applySupervisorLiveTick(.placeholder)
  }

  public func isSupervisorBackgroundActivityScheduledForTesting() -> Bool {
    supervisorStack?.lifecycle.isBackgroundActivityScheduled ?? false
  }

  public func isSupervisorAuditRetentionScheduledForTesting() -> Bool {
    supervisorStack?.auditRetention?.isBackgroundActivityScheduled ?? false
  }

  public func forceSupervisorBackgroundActivityTickForTesting() async {
    await supervisorStack?.lifecycle.forceTick()
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
