import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store legacy containment races", .serialized)
struct HarnessMonitorStoreLegacyContainmentRaceTests {
  @Test("Failure teardown completes before containment recovery starts")
  func failureTeardownPrecedesRecovery() async throws {
    let shutdownGate = LegacyContainmentVoidGate()
    let client = RecordingHarnessClient()
    client.shutdownHandler = { await shutdownGate.wait() }
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    store.client = client

    let failure = Task {
      await store.recordControllerLegacyCleanupFailureIfNeeded(
        DaemonControlError.legacyManagedLaunchAgentCleanupFailed
      )
    }
    await waitForGate(shutdownGate)

    #expect(await daemon.recordedLegacyCleanupCallCount() == 0)
    #expect(await daemon.recordedBootstrapCallCount() == 0)
    #expect(await daemon.recordedWarmUpCallCount() == 0)

    await shutdownGate.release()
    await failure.value
    await store.prepareForTermination()
  }

  @Test("Connect rejects credential sync after containment failure")
  func connectRejectsCredentialSyncAfterContainmentFailure() async throws {
    let runtimeGate = LegacyContainmentVoidGate()
    let client = RecordingHarnessClient()
    client.taskBoardGitRuntimeConfigHandler = {
      await runtimeGate.wait()
      return client.sampleTaskBoardGitRuntimeConfig()
    }
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    store.taskBoardDatabaseInstanceID = "accepted-task-board"
    let connectTask = Task { await store.connect(using: client) }

    await waitForGate(runtimeGate)
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    await store.recordControllerLegacyCleanupFailureIfNeeded(
      DaemonControlError.legacyManagedLaunchAgentCleanupFailed
    )
    await runtimeGate.release()
    await connectTask.value

    #expect(store.client == nil)
    #expect(store.taskBoardDatabaseInstanceID == "accepted-task-board")
    #expect(client.shutdownCallCount() == 1)
    assertNoCredentialMutations(client)
    await store.prepareForTermination()
  }

  @Test("Repeated ready rejects stale Task Board capabilities")
  func repeatedReadyRejectsStaleCapabilities() async throws {
    let capabilitiesGate = LegacyContainmentCapabilitiesGate()
    let client = RecordingHarnessClient()
    client.taskBoardCapabilitiesHandler = { await capabilitiesGate.wait() }
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    store.client = client
    store.taskBoardDatabaseInstanceID = "accepted-task-board"
    let readyTask = Task { @MainActor in
      var hasSeenReady = true
      return await store.processGlobalStreamEvent(
        DaemonPushEvent(recordedAt: "2026-08-10T00:00:00Z", sessionId: nil, kind: .ready),
        using: client,
        hasSeenReady: &hasSeenReady
      )
    }

    for _ in 0..<30 where await capabilitiesGate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await capabilitiesGate.hasEntered)
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    await store.recordControllerLegacyCleanupFailureIfNeeded(
      DaemonControlError.legacyManagedLaunchAgentCleanupFailed
    )
    await capabilitiesGate.release()

    #expect(await readyTask.value == false)
    #expect(store.client == nil)
    #expect(store.taskBoardDatabaseInstanceID == "accepted-task-board")
    assertNoCredentialMutations(client)
    await store.prepareForTermination()
  }

  private func waitForGate(_ gate: LegacyContainmentVoidGate) async {
    for _ in 0..<30 where await gate.hasEntered == false {
      try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(await gate.hasEntered)
  }

  private func assertNoCredentialMutations(_ client: RecordingHarnessClient) {
    let mutations = client.recordedCalls().filter { call in
      switch call {
      case .syncTaskBoardGitRuntimeKeyMaterial, .syncTaskBoardGitHubTokens,
        .syncTaskBoardOpenRouterToken:
        true
      default:
        false
      }
    }
    #expect(mutations.isEmpty)
  }
}
