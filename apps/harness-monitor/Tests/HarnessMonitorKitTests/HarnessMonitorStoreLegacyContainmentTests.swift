import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store legacy containment")
struct HarnessMonitorStoreLegacyContainmentTests {
  @Test("Cancelled cleanup does not authorize reconnect")
  func cancelledCleanupDoesNotAuthorizeReconnect() async throws {
    let daemon = RecordingDaemonController(legacyCleanupError: CancellationError())
    let store = HarnessMonitorStore(daemonController: daemon)

    await #expect(throws: CancellationError.self) {
      try await store.requireLegacyManagedLaunchAgentCleanupOrThrow()
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(await daemon.recordedBootstrapCallCount() == 0)
    #expect(await daemon.recordedWarmUpCallCount() == 0)
    #expect(store.isReconnecting == false)
    await store.prepareForTermination()
  }

  @Test("Cancelled cleanup failure and recovery stay offline")
  func cancelledCleanupFailureAndRecoveryStayOffline() async throws {
    let daemon = RecordingDaemonController(legacyCleanupError: CancellationError())
    let store = HarnessMonitorStore(daemonController: daemon)

    await #expect(throws: CancellationError.self) {
      try await store.requireLegacyManagedLaunchAgentCleanupOrThrow()
    }
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    let failureCalls = await daemon.recordedLegacyCleanupCallCount()
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<20 where await daemon.recordedLegacyCleanupCallCount() == failureCalls {
      try await Task.sleep(for: .milliseconds(10))
    }
    await daemon.setLegacyCleanupError(nil)
    store.legacyManagedLaunchAgentContainment.requestCheck()
    try await Task.sleep(for: .milliseconds(50))

    #expect(await daemon.recordedWarmUpCallCount() == 0)
    #expect(store.isReconnecting == false)
    #expect(store.connection.legacyContainmentHealthy)
    #expect(
      store.connectionState
        == .offline(LegacyManagedLaunchAgentCleanup.failureMessage)
    )
    await store.prepareForTermination()
  }

  @Test("In-flight relay client is rejected after containment failure")
  func inFlightRelayClientIsRejectedAfterContainmentFailure() async throws {
    let gate = LegacyContainmentWarmUpGate()
    let candidate = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      warmUpHandler: {
        await gate.wait()
        return candidate
      }
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.hasBootstrapped = true
    let relayTask = Task { try await store.clientForMobileRelay() }

    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await gate.hasEntered)
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    let cleanupCalls = await daemon.recordedLegacyCleanupCallCount()
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where await daemon.recordedLegacyCleanupCallCount() == cleanupCalls {
      try await Task.sleep(for: .milliseconds(20))
    }
    await gate.release()

    await #expect(throws: DaemonControlError.self) {
      _ = try await relayTask.value
    }
    #expect(candidate.shutdownCallCount() == 1)
    #expect(store.mobileRelayBackgroundClient == nil)
    #expect(store.connection.legacyContainmentHealthy == false)
    await store.prepareForTermination()
  }

  @Test("Task Board Host fallback rejects stale client")
  func taskBoardHostFallbackRejectsStaleClient() async throws {
    try await assertTaskBoardFallbackRejectsStaleClient(surface: .host)
  }

  @Test("Task Board Settings fallback rejects stale client")
  func taskBoardSettingsFallbackRejectsStaleClient() async throws {
    try await assertTaskBoardFallbackRejectsStaleClient(surface: .settings)
  }

  @Test("Task Board Host existing client rejects stale capabilities")
  func taskBoardHostExistingClientRejectsStaleCapabilities() async throws {
    try await assertTaskBoardExistingClientRejectsStaleCapabilities(surface: .host)
  }

  @Test("Task Board Settings existing client rejects stale capabilities")
  func taskBoardSettingsExistingClientRejectsStaleCapabilities() async throws {
    try await assertTaskBoardExistingClientRejectsStaleCapabilities(surface: .settings)
  }

  @Test("Termination rejects an in-flight relay client")
  func terminationRejectsInFlightRelayClient() async throws {
    let gate = LegacyContainmentWarmUpGate()
    let candidate = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      warmUpHandler: {
        await gate.wait()
        return candidate
      }
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.hasBootstrapped = true
    let relayTask = Task { try await store.clientForMobileRelay() }

    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.prepareForTermination()
    await gate.release()

    await #expect(throws: DaemonControlError.self) {
      _ = try await relayTask.value
    }
    #expect(candidate.shutdownCallCount() == 1)
    #expect(store.mobileRelayBackgroundClient == nil)
  }

  private func assertTaskBoardFallbackRejectsStaleClient(
    surface: TaskBoardFallbackSurface
  ) async throws {
    let gate = LegacyContainmentCapabilitiesGate()
    let candidate = RecordingHarnessClient()
    candidate.taskBoardCapabilitiesHandler = { await gate.wait() }
    let daemon = RecordingDaemonController(client: candidate)
    let store = HarnessMonitorStore(daemonController: daemon)
    store.hasBootstrapped = true
    store.taskBoardDatabaseInstanceID = "accepted-task-board"
    store.contentUI.dashboard.taskBoardRevision = 41
    store.taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID =
      "accepted-task-board"
    let request = Task {
      switch surface {
      case .host:
        _ = try await store.taskBoardHostSnapshot()
      case .settings:
        _ = try await store.taskBoardGitSettingsSnapshot()
      }
    }

    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await gate.hasEntered)
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    let cleanupCalls = await daemon.recordedLegacyCleanupCallCount()
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where await daemon.recordedLegacyCleanupCallCount() == cleanupCalls {
      try await Task.sleep(for: .milliseconds(20))
    }
    await gate.release()

    await #expect(throws: DaemonControlError.self) {
      try await request.value
    }
    #expect(candidate.shutdownCallCount() == 1)
    #expect(store.client == nil)
    #expect(store.taskBoardDatabaseInstanceID == "accepted-task-board")
    #expect(store.contentUI.dashboard.taskBoardRevision == 41)
    #expect(
      store.taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID
        == "accepted-task-board"
    )
    await store.prepareForTermination()
  }

  private func assertTaskBoardExistingClientRejectsStaleCapabilities(
    surface: TaskBoardFallbackSurface
  ) async throws {
    let gate = LegacyContainmentCapabilitiesGate()
    let candidate = RecordingHarnessClient()
    candidate.taskBoardCapabilitiesHandler = { await gate.wait() }
    let daemon = RecordingDaemonController(client: candidate)
    let store = HarnessMonitorStore(daemonController: daemon)
    _ = await store.requireLegacyManagedLaunchAgentCleanup()
    store.hasBootstrapped = true
    store.client = candidate
    store.taskBoardDatabaseInstanceID = "accepted-task-board"
    store.contentUI.dashboard.taskBoardRevision = 41
    store.taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID =
      "accepted-task-board"
    let request = Task {
      switch surface {
      case .host:
        _ = try await store.taskBoardHostSnapshot()
      case .settings:
        _ = try await store.taskBoardGitSettingsSnapshot()
      }
    }

    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where store.connection.legacyContainmentHealthy {
      try await Task.sleep(for: .milliseconds(20))
    }
    await gate.release()

    await #expect(throws: DaemonControlError.self) {
      try await request.value
    }
    #expect(candidate.shutdownCallCount() == 1)
    #expect(store.client == nil)
    #expect(store.taskBoardDatabaseInstanceID == "accepted-task-board")
    #expect(store.contentUI.dashboard.taskBoardRevision == 41)
    #expect(
      store.taskBoardRuntimeState.connection.lastConnectedDatabaseInstanceID
        == "accepted-task-board"
    )
    await store.prepareForTermination()
  }

  @Test("Registration is revalidated after concurrent containment failure")
  func registrationIsRevalidatedAfterConcurrentContainmentFailure() async throws {
    let gate = LegacyContainmentWarmUpGate()
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registerLaunchAgentHandler: { await gate.wait() }
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    let bootstrapTask = Task { await store.bootstrap() }

    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await gate.hasEntered)
    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    let cleanupCalls = await daemon.recordedLegacyCleanupCallCount()
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where await daemon.recordedLegacyCleanupCallCount() == cleanupCalls {
      try await Task.sleep(for: .milliseconds(20))
    }
    await gate.release()
    await bootstrapTask.value

    #expect(await daemon.recordedRegisterLaunchAgentCallCount() == 1)
    #expect(await daemon.recordedWarmUpCallCount() == 0)
    guard case .offline = store.connectionState else {
      Issue.record("Containment failure must leave the Store offline")
      await store.prepareForTermination()
      return
    }
    await store.prepareForTermination()
  }

  @Test("Post-registration cleanup failure recovers without restarting the app")
  func postRegistrationCleanupFailureRecoversAutomatically() async throws {
    let registration = LegacyContainmentRegistrationAttempt()
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registerLaunchAgentHandler: { try await registration.run() }
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()
    for _ in 0..<30 where store.connectionState != .online {
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedRegisterLaunchAgentCallCount() == 2)
    #expect(await daemon.recordedWarmUpCallCount() >= 1)
    await store.prepareForTermination()
  }

  @Test("Termination skips deferred refresh while containment is unhealthy")
  func terminationSkipsDeferredRefreshWhileContainmentIsUnhealthy() async {
    let daemon = RecordingDaemonController(
      deferredManagedLaunchAgentRefreshResult: true,
      legacyCleanupError: DaemonControlError.commandFailed("cleanup failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    _ = await store.requireLegacyManagedLaunchAgentCleanup()
    await store.prepareForTermination()

    #expect(await daemon.recordedDeferredManagedLaunchAgentRefreshCallCount() == 0)
  }

  @Test("Termination rechecks cleanup after deferred refresh")
  func terminationRechecksCleanupAfterDeferredRefresh() async {
    let daemon = RecordingDaemonController(
      deferredManagedLaunchAgentRefreshResult: true
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.prepareForTermination()

    #expect(await daemon.recordedDeferredManagedLaunchAgentRefreshCallCount() == 1)
    #expect(await daemon.recordedLegacyCleanupCallCount() == 1)
  }

  @Test("Containment failure closes and rejects the relay client")
  func containmentFailureClosesAndRejectsRelayClient() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("cleanup failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.mobileRelayBackgroundClient = PreviewHarnessClient()

    await #expect(throws: DaemonControlError.self) {
      try await store.requireLegacyManagedLaunchAgentCleanupOrThrow()
    }

    #expect(store.mobileRelayBackgroundClient == nil)
    await #expect(throws: DaemonControlError.self) {
      _ = try await store.clientForMobileRelay()
    }
    await store.prepareForTermination()
  }

  @Test("Managed bootstrap performs one legacy cleanup preflight")
  func managedBootstrapPerformsOneLegacyCleanupPreflight() async {
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedLegacyCleanupCallCount() == 1)
    await store.prepareForTermination()
  }

  @Test("Transient cleanup failure reconnects after containment succeeds")
  func transientCleanupFailureReconnectsAfterRecovery() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("cleanup failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()
    #expect(
      store.connectionState
        == .offline(LegacyManagedLaunchAgentCleanup.failureMessage)
    )

    await daemon.setLegacyCleanupError(nil)
    for _ in 0..<30 where store.connectionState != .online {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(store.connectionState == .online)
    #expect(await daemon.recordedLegacyCleanupCallCount() >= 2)
    await store.prepareForTermination()
  }

  @Test("New containment failure invalidates recovering connection")
  func newFailureInvalidatesRecoveringConnection() async throws {
    let gate = LegacyContainmentWarmUpGate()
    let daemon = RecordingDaemonController(
      warmUpHandler: {
        await gate.wait()
        return PreviewHarnessClient()
      },
      legacyCleanupError: DaemonControlError.commandFailed("cleanup failed")
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()
    await daemon.setLegacyCleanupError(nil)
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await gate.hasEntered)

    await daemon.setLegacyCleanupError(
      DaemonControlError.commandFailed("legacy service returned")
    )
    let cleanupCalls = await daemon.recordedLegacyCleanupCallCount()
    store.legacyManagedLaunchAgentContainment.requestCheck()
    for _ in 0..<30 where await daemon.recordedLegacyCleanupCallCount() == cleanupCalls {
      try await Task.sleep(for: .milliseconds(20))
    }
    await gate.release()
    try await Task.sleep(for: .milliseconds(50))

    #expect(
      store.connectionState
        == .offline(LegacyManagedLaunchAgentCleanup.failureMessage)
    )
    #expect(store.client == nil)
    await store.prepareForTermination()
  }
}
