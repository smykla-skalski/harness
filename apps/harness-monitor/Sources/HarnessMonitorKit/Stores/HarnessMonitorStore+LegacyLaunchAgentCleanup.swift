extension HarnessMonitorStore {
  func requireLegacyManagedLaunchAgentCleanup() async -> Bool {
    do {
      try await daemonController.requireLegacyManagedLaunchAgentCleanup()
      return true
    } catch {
      await applyLaunchAgentOfflineState(reason: LegacyManagedLaunchAgentCleanup.failureMessage)
      return false
    }
  }
}
