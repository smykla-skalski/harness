import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("Bootstrap with notRegistered agent registers and connects")
  func bootstrapWithNotRegisteredAgentRegistersAndConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedRegisterLaunchAgentCallCount() == 1)
  }

  @Test("Bootstrap with notFound agent registers and connects")
  func bootstrapWithNotFoundAgentRegistersAndConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .notFound
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedRegisterLaunchAgentCallCount() == 1)
  }

  @Test("Bootstrap with requiresApproval marks offline with approval message")
  func bootstrapWithRequiresApprovalMarksOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .requiresApproval
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("approval"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("Bootstrap with enabled state connects via awaitManifestWarmUp")
  func bootstrapWithEnabledStateConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
  }

  @Test("Bootstrap surfaces awaitManifestWarmUp failure as offline")
  func bootstrapSurfacesWarmUpFailureAsOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("Bootstrap refreshes the managed launch agent after stale warm-up failure")
  func bootstrapRefreshesManagedLaunchAgentAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpRecoveryDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedOperations() == ["warm-up", "remove", "register", "warm-up"])
  }

  @Test("Bootstrap recovers when the daemon becomes healthy after warm-up gives up")
  func bootstrapRecoversWhenDaemonBecomesHealthyAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpLateBootstrapDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(
      await daemon.recordedOperations()
        == ["warm-up", "remove", "register", "warm-up", "bootstrap"]
    )
  }

  @Test("Managed bootstrap restores cached state before warm-up completes")
  func managedBootstrapRestoresCachedStateBeforeWarmUpCompletes() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-cached-bootstrap",
        context: "Cached bootstrap session",
        status: .active,
        leaderId: "leader-cached-bootstrap",
        observeId: "observe-cached-bootstrap",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-04-13T20:59:00Z"
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-cached-bootstrap",
      workerName: "Worker Cached Bootstrap"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-cached-bootstrap",
      summary: "Cached bootstrap timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    let daemon = DelayedWarmUpDaemonController(
      client: client,
      warmUpDelay: .milliseconds(250)
    )
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )

    await store.cacheSessionList(
      [summary],
      projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)]
    )
    await store.cacheSessionDetail(detail, timeline: timeline)
    store.primeSessionSelection(summary.sessionId)

    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.connectionState == .connecting)
    #expect(store.sessions.map(\.sessionId) == [summary.sessionId])
    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isShowingCachedData)

    await bootstrapTask.value
    #expect(store.connectionState == .online)
  }

  @Test("Refresh overlaps bootstrap reads so startup latency tracks the slowest request")
  func refreshOverlapsBootstrapReads() async {
    let diagnosticsDelay: Duration = .milliseconds(250)
    let projectsDelay: Duration = .milliseconds(250)
    let sessionsDelay: Duration = .milliseconds(250)
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(diagnosticsDelay)
    client.configureProjectsDelay(projectsDelay)
    client.configureSessionsDelay(sessionsDelay)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await store.refresh(using: client, preserveSelection: true)

    let elapsed = startedAt.duration(to: clock.now)
    #expect(client.readCallCount(.diagnostics) == 1)
    #expect(client.readCallCount(.projects) == 1)
    #expect(client.readCallCount(.sessions) == 1)
    #expect(elapsed < .milliseconds(550))
  }

  @Test(
    "Bootstrap keeps the UI live while the first startup snapshot retries behind healthy daemon probes"
  )
  func bootstrapRetriesInitialSnapshotWarmUpAfterHealthSucceeds() async {
    let client = RecordingHarnessClient()
    client.configureDiagnosticsErrors([
      HarnessMonitorAPIError.server(code: 503, message: "daemon snapshot warming up")
    ])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.initialConnectRefreshRetryGracePeriod = .milliseconds(50)
    store.initialConnectRefreshRetryInterval = .milliseconds(1)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.contentUI.toolbar.connectionState == .online)
    #expect(store.contentUI.chrome.sessionDataAvailability == .live)
    #expect(client.readCallCount(.diagnostics) == 2)
    #expect(
      store.connectionEvents.contains { event in
        event.detail.contains("startup snapshot is still warming up")
      }
    )
  }

  @Test(
    "Bootstrap goes offline when snapshot endpoints fail persistently throughout the grace period"
  )
  func bootstrapGoesOfflineWhenSnapshotEndpointsFailPersistently() async {
    let client = RecordingHarnessClient()
    let persistentErrors: [any Error] = (0..<20).map { _ in
      HarnessMonitorAPIError.server(code: 503, message: "daemon snapshot warming up")
    }
    client.configureDiagnosticsErrors(persistentErrors)
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.initialConnectRefreshRetryGracePeriod = .milliseconds(50)
    store.initialConnectRefreshRetryInterval = .milliseconds(5)

    await store.bootstrap()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("503") || reason.contains("warming up"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
    #expect(client.readCallCount(.diagnostics) >= 2)
    #expect(
      store.connectionEvents.contains { event in
        event.detail.contains("startup snapshot is still warming up")
      }
    )
  }

  @Test("Bootstrap retry logs include the actual error for diagnosis")
  func bootstrapRetryLogsIncludeActualError() async {
    let client = RecordingHarnessClient()
    client.configureDiagnosticsErrors([
      HarnessMonitorAPIError.server(code: 503, message: "test error message xyz123"),
      HarnessMonitorAPIError.server(code: 503, message: "test error message xyz123"),
    ])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.initialConnectRefreshRetryGracePeriod = .milliseconds(50)
    store.initialConnectRefreshRetryInterval = .milliseconds(5)

    await store.bootstrap()

    let retryEvent = store.connectionEvents.first { event in
      event.detail.contains("startup snapshot is still warming up")
    }
    #expect(retryEvent != nil)
    if let retryEvent {
      #expect(
        retryEvent.detail.contains("xyz123"),
        "Retry message should include actual error: \(retryEvent.detail)"
      )
    }
  }

  @Test("Bootstrap retry logs identify the failing startup snapshot component and decode path")
  func bootstrapRetryLogsIdentifyFailingSnapshotComponentAndDecodePath() async {
    let client = RecordingHarnessClient()
    client.configureSessionsErrors([
      DecodingError.dataCorrupted(
        .init(
          codingPath: [
            SnapshotCodingKey(intValue: 0)!,
            SnapshotCodingKey(stringValue: "status")!,
          ],
          debugDescription:
            "Cannot initialize SessionStatus from invalid String value leaderless_degraded"
        )
      )
    ])
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )
    store.initialConnectRefreshRetryGracePeriod = .milliseconds(50)
    store.initialConnectRefreshRetryInterval = .milliseconds(5)

    await store.bootstrap()

    #expect(store.connectionState == .online)

    let retryEvent = store.connectionEvents.first { event in
      event.detail.contains("startup snapshot is still warming up")
    }
    #expect(retryEvent != nil)
    if let retryEvent {
      #expect(retryEvent.detail.contains("Startup snapshot sessions failed"))
      #expect(retryEvent.detail.contains("[0].status"))
      #expect(retryEvent.detail.contains("leaderless_degraded"))
    }
  }
  @Test("Bootstrap keeps a manifest watcher armed after managed warm-up failure")
  func bootstrapStartsManifestWatcherAfterManagedWarmUpFailure() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
    #expect(store.manifestWatcher != nil)
    #expect(
      store.connectionEvents.contains { event in
        event.detail.contains(
          "Managed daemon did not become healthy; refreshing the bundled launch agent")
      }
    )
  }

  @Test("Bootstrap replays a reconnect request queued during warm-up")
  func bootstrapReplaysReconnectQueuedDuringWarmUp() async {
    let daemon = DelayedWarmUpDaemonController(warmUpDelay: .milliseconds(250))
    let store = HarnessMonitorStore(daemonController: daemon)

    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    try? await Task.sleep(for: .milliseconds(50))
    await store.reconnect()
    await bootstrapTask.value

    for _ in 0..<50 {
      if await daemon.recordedWarmUpCallCount() == 2, store.connectionState == .online {
        break
      }
      try? await Task.sleep(for: .milliseconds(20))
    }

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedWarmUpCallCount() == 2)
  }

}

private struct SnapshotCodingKey: CodingKey, Sendable {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
