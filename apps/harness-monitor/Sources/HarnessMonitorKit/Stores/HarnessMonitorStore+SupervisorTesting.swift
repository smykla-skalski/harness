import Foundation

extension HarnessMonitorStore {
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
    await service.setQuietHoursWindow(window)
  }
}
