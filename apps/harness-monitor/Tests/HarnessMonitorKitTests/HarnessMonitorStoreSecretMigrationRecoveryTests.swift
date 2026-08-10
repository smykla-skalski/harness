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

  @Test("A newer no-prompt connection resolves superseded consent")
  func newerConnectionResolvesSupersededConsent() async throws {
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
    let supersededConnect = Task { await store.connect(using: replacementClient) }
    #expect(await waitUntil { store.presentedSheet != nil })

    await store.connect(using: initialClient)
    await supersededConnect.value

    #expect(store.presentedSheet == nil)
    #expect((store.apiClient as? RecordingHarnessClient) === initialClient)
    #expect(store.taskBoardDatabaseInstanceID == "daemon-A")
    #expect(replacementClient.shutdownCallCount() == 1)
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

  @Test("Task Board fallback rejects failed forced credential sync")
  func taskBoardFallbackRejectsFailedCredentialSync() async {
    let candidate = RecordingHarnessClient()
    candidate.configureTaskBoardGitHubTokensSyncError(
      HarnessMonitorAPIError.server(code: 500, message: "token sync failed")
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: candidate)
    )
    store.hasBootstrapped = true

    let succeeded: Bool
    do {
      _ = try await store.taskBoardHostSnapshot()
      succeeded = true
    } catch {
      succeeded = false
    }

    #expect(succeeded == false)
    #expect(store.client == nil)
    #expect(candidate.shutdownCallCount() == 1)
    await store.prepareForTermination()
  }

  @Test("Task Board fallback rejects failed runtime secret handoff")
  func taskBoardFallbackRejectsFailedRuntimeSecretHandoff() async {
    let candidate = RecordingHarnessClient()
    candidate.taskBoardSecretHandoffPrepareValue =
      TaskBoardGitRuntimeSecretHandoffPrepareResponse(
        prepared: true,
        migrationID: "migration-1",
        digest: "digest-1",
        runtime: TaskBoardGitRuntimeConfig()
      )
    candidate.configureTaskBoardSecretHandoffAckError(
      HarnessMonitorAPIError.server(code: 500, message: "ack failed")
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: candidate)
    )
    store.hasBootstrapped = true

    let succeeded: Bool
    do {
      _ = try await store.taskBoardHostSnapshot()
      succeeded = true
    } catch {
      succeeded = false
    }

    #expect(succeeded == false)
    #expect(store.client == nil)
    #expect(candidate.shutdownCallCount() == 1)
    await store.prepareForTermination()
  }
}
