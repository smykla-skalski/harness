import Foundation
import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreRemoteConnectionTests {
  @Test("Remote stream closure keeps retrying until the server returns")
  func remoteStreamClosureKeepsRetryingUntilServerReturns() async throws {
    let fixture = try RemoteStoreFixture()
    let initialClient = RecordingHarnessClient()
    let replacementClient = RecordingHarnessClient()
    let sleeper = RecordingRemoteDaemonReconnectSleeper(behavior: .immediate)
    let daemon = RecordingDaemonController(
      bootstrapOutcomes: [
        .success(initialClient),
        .failure(URLError(.cancelled)),
        .failure(URLError(.cannotConnectToHost)),
        .failure(URLError(.networkConnectionLost)),
        .success(replacementClient),
      ],
      bootstrapChecksCancellation: true
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.connection.remoteDaemonReconnectSleeper = sleeper

    await store.bootstrap()
    #expect(store.connectionState == .online)
    #expect(await daemon.recordedBootstrapCallCount() == 1)

    initialClient.configureGlobalStream(
      events: [],
      error: WebSocketTransportError.connectionClosed,
      failureCount: 1
    )
    initialClient.configureSessionStream(
      events: [],
      error: WebSocketTransportError.connectionClosed,
      for: PreviewFixtures.summary.sessionId
    )
    store.startGlobalStream(using: initialClient)
    store.startSessionStream(using: initialClient, sessionID: PreviewFixtures.summary.sessionId)

    try await waitForRemoteReconnect {
      if await daemon.recordedBootstrapCallCount() >= 5,
        store.connectionState == .online,
        !store.isReconnecting
      {
        return true
      }
      return false
    }

    #expect(await daemon.recordedBootstrapCallCount() == 5)
    #expect(
      await sleeper.recordedDelays() == [
        .milliseconds(500), .seconds(1), .seconds(2),
      ]
    )
    #expect(store.connectionState == .online)
    #expect((store.apiClient as? RecordingHarnessClient) === replacementClient)
    #expect(store.globalStreamTask != nil)
    #expect(initialClient.shutdownCallCount() == 1)
    await store.prepareForTermination()
  }

  @Test("Remote initial snapshot failure closes discarded client before retry")
  func remoteInitialSnapshotFailureClosesDiscardedClientBeforeRetry() async throws {
    let fixture = try RemoteStoreFixture()
    let failingClient = RecordingHarnessClient()
    failingClient.configureDiagnosticsErrors([URLError(.cannotConnectToHost)])
    let replacementClient = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      bootstrapOutcomes: [
        .success(failingClient),
        .success(replacementClient),
      ]
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.initialConnectRefreshRetryGracePeriod = .zero

    await store.bootstrap()
    #expect(failingClient.shutdownCallCount() == 1)

    for _ in 0..<100 {
      if await daemon.recordedBootstrapCallCount() == 2,
        store.connectionState == .online
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    #expect(await daemon.recordedBootstrapCallCount() == 2)
    #expect(store.connectionState == .online)
    #expect((store.apiClient as? RecordingHarnessClient) === replacementClient)
    await store.prepareForTermination()
  }

  @Test("Remote refresh failure closes discarded client before retry")
  func remoteRefreshFailureClosesDiscardedClientBeforeRetry() async throws {
    let fixture = try RemoteStoreFixture()
    let initialClient = RecordingHarnessClient()
    let replacementClient = RecordingHarnessClient()
    let daemon = RecordingDaemonController(
      bootstrapOutcomes: [
        .success(initialClient),
        .success(replacementClient),
      ]
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    await store.bootstrap()
    initialClient.configureDiagnosticsErrors([URLError(.cannotConnectToHost)])

    await store.refresh(using: initialClient, preserveSelection: true)
    #expect(initialClient.shutdownCallCount() == 1)

    for _ in 0..<100 {
      if await daemon.recordedBootstrapCallCount() == 2,
        store.connectionState == .online
      {
        break
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    #expect(await daemon.recordedBootstrapCallCount() == 2)
    #expect(store.connectionState == .online)
    #expect((store.apiClient as? RecordingHarnessClient) === replacementClient)
    await store.prepareForTermination()
  }

  @Test("Remote snapshot 401 revokes the profile without retrying")
  func remoteSnapshotUnauthorizedRevokesProfileWithoutRetrying() async throws {
    let fixture = try RemoteStoreFixture()
    let client = RecordingHarnessClient()
    client.configureDiagnosticsErrors([
      HarnessMonitorAPIError.server(code: 401, message: "unauthorized")
    ])
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.initialConnectRefreshRetryGracePeriod = .zero

    await store.bootstrap()

    #expect(client.shutdownCallCount() == 1)
    #expect(store.remoteDaemonProfile?.status == .revoked)
    #expect(try fixture.tokenStore.loadToken(profileID: fixture.profile.id) == nil)
    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 1)
  }

  @Test("Remote incompatible task board stops retrying")
  func remoteIncompatibleTaskBoardStopsRetrying() async throws {
    let fixture = try RemoteStoreFixture()
    let client = RecordingHarnessClient()
    client.taskBoardCapabilitiesValue = TaskBoardCapabilities(
      storage: "files",
      revision: 1,
      instanceID: "legacy-files"
    )
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    await store.bootstrap()

    #expect(client.shutdownCallCount() == 1)
    #expect(store.remoteDaemonProfile?.status == .active)
    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 1)
  }

  @Test("Termination during remote connect cannot republish the connection")
  func terminationDuringRemoteConnectCannotRepublishConnection() async throws {
    let fixture = try RemoteStoreFixture()
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(.milliseconds(200))
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      remoteDaemonServices: fixture.services
    )
    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    for _ in 0..<100 {
      if client.readCallCount(.diagnostics) > 0 {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    await store.prepareForTermination()
    await bootstrapTask.value

    #expect(client.shutdownCallCount() == 1)
    #expect(store.apiClient == nil)
    #expect(store.connectionState == .idle)
    #expect(store.globalStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.remoteDaemonReconnectTask == nil)
  }

  @Test("App inactivity during remote connect cannot republish the connection")
  func appInactivityDuringRemoteConnectCannotRepublishConnection() async throws {
    let fixture = try RemoteStoreFixture()
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(.milliseconds(200))
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      remoteDaemonServices: fixture.services
    )
    store.appInactivitySuspendDelay = .zero
    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    for _ in 0..<100 {
      if client.readCallCount(.diagnostics) > 0 {
        break
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    await store.suspendLiveConnectionForAppInactivity()
    await bootstrapTask.value

    #expect(client.shutdownCallCount() == 1)
    #expect(store.isAppLifecycleSuspended)
    #expect(store.apiClient == nil)
    #expect(store.connectionState == .idle)
    #expect(store.globalStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.remoteDaemonReconnectTask == nil)
  }

  @Test("Remote transport cancellation retries while observation remains active")
  func remoteTransportCancellationRetriesWhileObservationRemainsActive() async throws {
    let fixture = try RemoteStoreFixture()
    let replacementClient = RecordingHarnessClient()
    let sleeper = RecordingRemoteDaemonReconnectSleeper(behavior: .immediate)
    let daemon = RecordingDaemonController(
      bootstrapOutcomes: [
        .failure(URLError(.cancelled)),
        .success(replacementClient),
      ]
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.connection.remoteDaemonReconnectSleeper = sleeper

    await store.bootstrap()
    try await waitForRemoteReconnect {
      store.connectionState == .online
    }

    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 2)
    #expect(await sleeper.recordedDelays() == [.milliseconds(500)])
    #expect((store.apiClient as? RecordingHarnessClient) === replacementClient)
    await store.prepareForTermination()
  }

  @Test("A cancelled observer task cannot start remote reconnect")
  func cancelledObserverTaskCannotStartRemoteReconnect() async throws {
    let fixture = try RemoteStoreFixture()
    let sleeper = RecordingRemoteDaemonReconnectSleeper(behavior: .immediate)
    let daemon = RecordingDaemonController()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.connection.remoteDaemonReconnectSleeper = sleeper
    store.connectionState = .offline("remote unavailable")

    let observer = Task { @MainActor in
      do {
        try await Task.sleep(for: .seconds(30))
      } catch {}
      #expect(Task.isCancelled)
      store.scheduleRemoteDaemonReconnect(after: CancellationError())
    }
    await Task.yield()
    observer.cancel()
    await observer.value

    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await sleeper.recordedDelays().isEmpty)
    #expect(await daemon.recordedBootstrapCallCount() == 0)
  }

  @Test("Remote reconnect uses capped exponential backoff")
  func remoteReconnectUsesCappedExponentialBackoff() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    let delays = (0...6).map { store.reconnectDelay(for: $0) }

    #expect(
      delays == [
        .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
        .seconds(8), .seconds(8),
      ]
    )
  }

  @Test("Termination cancels pending remote reconnect backoff")
  func terminationCancelsPendingRemoteReconnectBackoff() async throws {
    let (store, daemon, sleeper) = try await makePendingReconnectStore()

    #expect(await daemon.recordedBootstrapCallCount() == 0)
    #expect(store.remoteDaemonReconnectTask != nil)

    await store.prepareForTermination()
    try await waitForRemoteReconnect {
      await sleeper.recordedCancellationCount() == 1
    }

    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 0)
  }

  @Test("App inactivity cancels pending remote reconnect backoff")
  func appInactivityCancelsPendingRemoteReconnectBackoff() async throws {
    let (store, daemon, sleeper) = try await makePendingReconnectStore()
    store.appInactivitySuspendDelay = .zero

    await store.suspendLiveConnectionForAppInactivity()
    try await waitForRemoteReconnect {
      await sleeper.recordedCancellationCount() == 1
    }

    #expect(store.isAppLifecycleSuspended)
    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 0)
  }

  @Test("Repeated remote failures share one reconnect loop")
  func repeatedRemoteFailuresShareOneReconnectLoop() async throws {
    let (store, daemon, sleeper) = try await makePendingReconnectStore()
    let generation = store.remoteDaemonReconnectGeneration

    store.scheduleRemoteDaemonReconnect(after: URLError(.timedOut))
    store.scheduleRemoteDaemonReconnect(after: URLError(.networkConnectionLost))
    for _ in 0..<10 {
      await Task.yield()
    }

    #expect(store.remoteDaemonReconnectGeneration == generation)
    #expect(await sleeper.recordedDelays() == [.milliseconds(500)])
    #expect(await daemon.recordedBootstrapCallCount() == 0)

    store.stopRemoteDaemonReconnect()
    try await waitForRemoteReconnect {
      await sleeper.recordedCancellationCount() == 1
    }
  }

  @Test(
    "Remote terminal client errors do not retry",
    arguments: [403, 426]
  )
  func remoteTerminalClientErrorsDoNotRetry(code: Int) async throws {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController(
      bootstrapError: HarnessMonitorAPIError.server(code: code, message: "terminal failure")
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )

    await store.bootstrap()

    #expect(store.remoteDaemonProfile?.status == .active)
    #expect(store.remoteDaemonReconnectTask == nil)
    #expect(await daemon.recordedBootstrapCallCount() == 1)
  }

  private func makePendingReconnectStore() async throws -> (
    HarnessMonitorStore, RecordingDaemonController, RecordingRemoteDaemonReconnectSleeper
  ) {
    let fixture = try RemoteStoreFixture()
    let daemon = RecordingDaemonController()
    let sleeper = RecordingRemoteDaemonReconnectSleeper(behavior: .suspended)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      remoteDaemonServices: fixture.services
    )
    store.connection.remoteDaemonReconnectSleeper = sleeper
    store.connectionState = .offline("remote unavailable")
    store.scheduleRemoteDaemonReconnect(after: URLError(.cannotConnectToHost))
    try await waitForRemoteReconnect {
      await sleeper.recordedDelays() == [.milliseconds(500)]
    }
    return (store, daemon, sleeper)
  }

  private func waitForRemoteReconnect(
    _ condition: @escaping @MainActor () async -> Bool
  ) async throws {
    for _ in 0..<100 {
      if await condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for remote daemon reconnect state")
  }
}

private actor RecordingRemoteDaemonReconnectSleeper: RemoteDaemonReconnectSleeping {
  enum Behavior: Sendable {
    case immediate
    case suspended
  }

  private let behavior: Behavior
  private var delays: [Duration] = []
  private var cancellationCount = 0

  init(behavior: Behavior) {
    self.behavior = behavior
  }

  func sleep(for delay: Duration) async throws {
    delays.append(delay)
    switch behavior {
    case .immediate:
      await Task.yield()
      try Task.checkCancellation()
    case .suspended:
      do {
        try await Task.sleep(for: .seconds(3_600))
      } catch {
        cancellationCount += 1
        throw error
      }
    }
  }

  func recordedDelays() -> [Duration] {
    delays
  }

  func recordedCancellationCount() -> Int {
    cancellationCount
  }
}
