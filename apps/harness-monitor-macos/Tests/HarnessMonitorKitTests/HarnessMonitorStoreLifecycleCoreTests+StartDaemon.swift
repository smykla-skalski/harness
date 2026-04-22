import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("startDaemon registers the launch agent when notRegistered then connects")
  func startDaemonRegistersWhenNotRegisteredThenConnects() async {
    let daemon = RecordingDaemonController(launchAgentInstalled: false)
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
  }

  @Test("startDaemon with requiresApproval marks offline without warming up")
  func startDaemonWithRequiresApprovalMarksOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .requiresApproval,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("approval"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("startDaemon with enabled agent connects via awaitManifestWarmUp")
  func startDaemonWithEnabledAgentConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
  }

  @Test("startDaemon surfaces awaitManifestWarmUp failure as offline")
  func startDaemonSurfacesWarmUpFailureAsOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("startDaemon refreshes the managed launch agent after stale warm-up failure")
  func startDaemonRefreshesManagedLaunchAgentAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpRecoveryDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedOperations() == ["warm-up", "remove", "register", "warm-up"])
  }

  @Test("startDaemon recovers when the daemon becomes healthy after warm-up gives up")
  func startDaemonRecoversWhenDaemonBecomesHealthyAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpLateBootstrapDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
    #expect(
      await daemon.recordedOperations()
        == ["warm-up", "remove", "register", "warm-up", "bootstrap"]
    )
  }

  @Test("startDaemon refreshes the managed launch agent after a daemon version mismatch")
  func startDaemonRefreshesManagedLaunchAgentAfterDaemonVersionMismatch() async {
    let daemon = ManagedDaemonVersionRecoveryDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedOperations() == ["warm-up", "remove", "register", "warm-up"])
  }

  @Test("startDaemon keeps a manifest watcher armed after managed warm-up failure")
  func startDaemonStartsManifestWatcherAfterManagedWarmUpFailure() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
    #expect(store.manifestWatcher != nil)
  }

  @Test("reconnect stops the active manifest watcher while managed bootstrap is in flight")
  func reconnectStopsManifestWatcherDuringBootstrap() async {
    let daemon = DelayedWarmUpDaemonController(warmUpDelay: .milliseconds(250))
    let store = HarnessMonitorStore(daemonController: daemon)
    store.manifestWatcher = ManifestWatcher(currentEndpoint: "http://127.0.0.1:9999") { _ in }

    let reconnectTask = Task { @MainActor in
      await store.reconnect()
    }

    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.isReconnecting)
    #expect(store.manifestWatcher == nil)

    await reconnectTask.value

    #expect(store.connectionState == .online)
    #expect(store.manifestWatcher != nil)
  }

  @Test("managed launch-agent refresh is throttled across repeated reconnect failures")
  func managedLaunchAgentRefreshIsThrottledAcrossReconnectFailures() async {
    let daemon = ManagedLaunchAgentRefreshThrottleDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)
    store.managedLaunchAgentRefreshMinimumInterval = .seconds(10)

    await store.reconnect()
    await store.reconnect()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record(
        "expected offline state after repeated warm-up failures, got \(store.connectionState)")
    }
    #expect(
      await daemon.recordedOperations()
        == ["warm-up", "remove", "register", "warm-up", "warm-up"]
    )
  }

  @Test("reconnect replays a request queued while reconnect is already in flight")
  func reconnectReplaysQueuedRequestAfterCurrentAttemptConnects() async {
    let daemon = DelayedWarmUpDaemonController(warmUpDelay: .milliseconds(250))
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()
    #expect(await daemon.recordedWarmUpCallCount() == 1)

    let reconnectTask = Task { @MainActor in
      await store.reconnect()
    }

    try? await Task.sleep(for: .milliseconds(50))
    await store.reconnect()
    await reconnectTask.value

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedWarmUpCallCount() == 3)
  }

  @Test("Prepare for termination cancels background work and shuts down the client")
  func prepareForTerminationCancelsBackgroundWorkAndShutsDownClient() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.presentSuccessFeedback("Refresh")

    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(store.currentSuccessFeedbackMessage == "Refresh")

    await store.prepareForTermination()

    #expect(store.client == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(client.shutdownCallCount() == 1)
  }

  @Test("App inactivity suspends the live daemon connection without clearing selection")
  func appInactivitySuspendsLiveDaemonConnection() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.appInactivitySuspendDelay = .milliseconds(50)
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let selectedSessionID = store.selectedSessionID
    let selectedSession = store.selectedSession

    await store.suspendLiveConnectionForAppInactivity()

    #expect(store.connectionState == .online)
    #expect(store.client != nil)
    #expect(client.shutdownCallCount() == 0)

    try? await Task.sleep(for: .milliseconds(100))

    #expect(store.connectionState == .idle)
    #expect(store.client == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.selectedSessionID == selectedSessionID)
    #expect(store.selectedSession == selectedSession)
    #expect(client.shutdownCallCount() == 1)
  }

  @Test("App inactivity applies any deferred managed launch-agent refresh after suspending")
  func appInactivityAppliesDeferredManagedLaunchAgentRefresh() async {
    let client = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      client: client,
      deferredManagedLaunchAgentRefreshResult: true
    )
    let store = HarnessMonitorStore(daemonController: daemon)
    store.appInactivitySuspendDelay = .zero

    await store.bootstrap()
    await store.suspendLiveConnectionForAppInactivity()

    #expect(store.connectionState == .idle)
    #expect(store.client == nil)
    #expect(client.shutdownCallCount() == 1)
    #expect(await daemon.recordedDeferredManagedLaunchAgentRefreshCallCount() == 1)
  }

  @Test("App activation cancels a pending inactivity suspend")
  func appActivationCancelsPendingInactivitySuspend() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.appInactivitySuspendDelay = .milliseconds(50)

    await store.suspendLiveConnectionForAppInactivity()
    await store.resumeLiveConnectionAfterAppActivation()
    try? await Task.sleep(for: .milliseconds(100))

    #expect(store.connectionState == .online)
    #expect(store.client != nil)
    #expect(store.globalStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(client.shutdownCallCount() == 0)
  }

  @Test("App activation restores a daemon connection suspended for inactivity")
  func appActivationRestoresSuspendedDaemonConnection() async {
    let client = RecordingHarnessClient()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(daemonController: daemon)
    store.appInactivitySuspendDelay = .zero

    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    await store.suspendLiveConnectionForAppInactivity()

    await store.resumeLiveConnectionAfterAppActivation()

    #expect(store.connectionState == .online)
    #expect(store.client != nil)
    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(client.shutdownCallCount() == 1)
  }

}
