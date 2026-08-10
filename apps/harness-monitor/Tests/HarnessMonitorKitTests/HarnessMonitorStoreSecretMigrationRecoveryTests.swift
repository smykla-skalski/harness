import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor secret migration recovery")
struct HarnessMonitorStoreSecretMigrationRecoveryTests {
  @Test("Inactivity resolves pending consent before a replacement reconnects")
  func inactivityResolvesPendingConsentBeforeReconnect() async throws {
    let initialClient = RecordingHarnessClient()
    initialClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 1,
      instanceID: "daemon-A"
    )
    let credentials = InMemoryTaskBoardCredentialBundle()
    try credentials.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-A"),
      scope: .database("daemon-A")
    )
    let store = await makeBootstrappedStore(
      client: initialClient,
      credentialPersistence: credentials
    )
    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )
    let interruptedConnect = Task { await store.connect(using: replacementClient) }
    #expect(await waitUntil { store.presentedSheet != nil })

    await store.performAppInactivitySuspend()
    await interruptedConnect.value
    #expect(store.presentedSheet == nil)

    store.isAppLifecycleSuspended = false
    let resumedConnect = Task { await store.connect(using: replacementClient) }
    #expect(await waitUntil { store.presentedSheet != nil })
    store.resolveSecretMigrationConsent([.githubGlobalToken: true])
    await resumedConnect.value
    #expect(store.taskBoardDatabaseInstanceID == "daemon-B")
    await store.prepareForTermination()
  }

  @Test("Task Board fallback synchronizes a replacement daemon before adoption")
  func taskBoardFallbackSynchronizesReplacementBeforeAdoption() async throws {
    let connectionHistory = TaskBoardConnectionHistoryStore(defaults: nil)
    _ = connectionHistory.noteConnectedDatabaseInstance("daemon-A")
    let credentials = InMemoryTaskBoardCredentialBundle()
    try credentials.github.save(
      TaskBoardGitHubCredentialSnapshot(globalToken: "gh-token-A"),
      scope: .database("daemon-A")
    )
    let replacementClient = RecordingHarnessClient()
    replacementClient.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "database",
      revision: 2,
      instanceID: "daemon-B"
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: replacementClient),
      voiceCapture: NativeVoiceCaptureService(),
      taskBoardSettingsWorker: TaskBoardSettingsWorker(
        credentialPersistence: credentials.persistence,
        keyMaterialPersistence: InMemoryTaskBoardKeychainBundle().persistence
      ),
      taskBoardConnectionHistoryStore: connectionHistory
    )
    store.hasBootstrapped = true

    let snapshot = Task { try await store.taskBoardGitSettingsSnapshot() }
    #expect(await waitUntil { store.presentedSheet != nil })
    store.resolveSecretMigrationConsent([.githubGlobalToken: true])
    _ = try await snapshot.value

    #expect(store.taskBoardDatabaseInstanceID == "daemon-B")
    #expect(
      replacementClient.recordedCalls().contains {
        if case .syncTaskBoardGitHubTokens(let globalConfigured, _) = $0 {
          return globalConfigured
        }
        return false
      }
    )
    await store.prepareForTermination()
  }
}
