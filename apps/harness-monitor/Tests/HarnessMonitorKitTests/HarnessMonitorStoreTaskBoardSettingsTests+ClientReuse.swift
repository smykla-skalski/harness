import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreTaskBoardSettingsTests {
  @Test("Connected Task Board clients bypass launch-agent cleanup")
  func connectedTaskBoardClientsBypassLaunchAgentCleanup() async throws {
    let client = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("cleanup must stay off the hot path")
    )
    let credentialPersistence = InMemoryTaskBoardCredentialBundle()
    let keychainBundle = InMemoryTaskBoardKeychainBundle()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: TaskBoardSettingsWorker(
        credentialPersistence: credentialPersistence.persistence,
        keyMaterialPersistence: keychainBundle.persistence
      ),
      taskBoardConnectionHistoryStore: TaskBoardConnectionHistoryStore(defaults: nil)
    )
    store.client = client
    store.taskBoardDatabaseInstanceID = "task-board-live-client"

    _ = try await store.taskBoardHostSnapshot()
    _ = try await store.taskBoardGitSettingsSnapshot()

    #expect(await daemon.recordedLegacyCleanupCallCount() == 0)
  }
}
