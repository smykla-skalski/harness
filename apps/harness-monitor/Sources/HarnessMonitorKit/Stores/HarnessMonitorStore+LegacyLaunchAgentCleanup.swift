extension HarnessMonitorStore {
  func requireLegacyManagedLaunchAgentCleanup() async -> Bool {
    guard LegacyManagedLaunchAgentCleanup.runOnce() else {
      await applyLaunchAgentOfflineState(reason: LegacyManagedLaunchAgentCleanup.failureMessage)
      return false
    }
    return true
  }
}
