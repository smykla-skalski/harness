import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreExternalDaemonTests {
  @Test("External clients skip every managed containment entry point")
  func externalClientsSkipEveryManagedContainmentEntryPoint() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("managed-only containment ran")
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    #expect(await store.requireLegacyManagedLaunchAgentCleanup())
    try await store.requireLegacyManagedLaunchAgentCleanupOrThrow()

    #expect(await daemon.recordedLegacyCleanupCallCount() == 0)
  }

  @Test("External client fences ignore a stale managed-containment failure")
  func externalClientFencesIgnoreStaleManagedContainmentFailure() async throws {
    let candidate = RecordingHarnessClient()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: candidate),
      daemonOwnership: .external
    )
    store.connection.legacyContainmentHealthy = false

    #expect(await store.requireLegacyManagedLaunchAgentCleanup())
    let client = try await store.withLegacyContainmentClient { candidate }

    #expect(store.connection.legacyContainmentHealthy)
    #expect((client as? RecordingHarnessClient) === candidate)
    #expect(candidate.shutdownCallCount() == 0)
  }
}
