extension HarnessMonitorStore {
  func requireLegacyManagedLaunchAgentCleanup() async -> Bool {
    do {
      try await daemonController.requireLegacyManagedLaunchAgentCleanup()
      startLegacyManagedLaunchAgentContainment()
      return true
    } catch {
      startLegacyManagedLaunchAgentContainment()
      await applyLaunchAgentOfflineState(reason: LegacyManagedLaunchAgentCleanup.failureMessage)
      return false
    }
  }

  func requireLegacyManagedLaunchAgentCleanupOrThrow() async throws {
    do {
      try await daemonController.requireLegacyManagedLaunchAgentCleanup()
      startLegacyManagedLaunchAgentContainment()
    } catch {
      startLegacyManagedLaunchAgentContainment()
      throw error
    }
  }

  private func startLegacyManagedLaunchAgentContainment() {
    guard !usesRemoteDaemon else { return }
    legacyManagedLaunchAgentContainment.start(controller: daemonController)
  }
}
