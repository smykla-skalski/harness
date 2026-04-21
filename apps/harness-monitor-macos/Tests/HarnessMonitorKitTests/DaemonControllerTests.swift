import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon controller service management")
struct DaemonControllerTests {
  @Test(
    "awaitManifestWarmUp returns stale manifest immediately for external daemon when pid is dead")
  func awaitManifestWarmUpReturnsExternalStaleManifestImmediately() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .external,
        endpointProbe: { _ in false }
      )

      do {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(5))
        Issue.record("Expected externalDaemonManifestStale")
      } catch let error as DaemonControlError {
        guard case .externalDaemonManifestStale(let manifestPath) = error else {
          Issue.record("Expected externalDaemonManifestStale, got \(error)")
          return
        }
        #expect(manifestPath == HarnessMonitorPaths.manifestURL(using: environment).path)
      } catch {
        Issue.record("Expected DaemonControlError, got \(error)")
      }
    }
  }

  @Test(
    "awaitManifestWarmUp returns daemonDidNotStart promptly for managed daemon when pid is dead")
  func awaitManifestWarmUpReturnsManagedDaemonDidNotStartPromptly() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        endpointProbe: { _ in false },
        managedStaleManifestGracePeriod: .seconds(2)
      )
      let clock = ContinuousClock()
      let start = clock.now

      await #expect(throws: DaemonControlError.daemonDidNotStart) {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(5))
      }

      let elapsed = start.duration(to: clock.now)
      #expect(elapsed < .seconds(1))
    }
  }

  @Test(
    "awaitManifestWarmUp does not issue a stale HTTP bootstrap after a managed dead pid is detected"
  )
  func awaitManifestWarmUpSkipsFinalBootstrapForManagedDeadPid() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let client = RecordingHarnessClient()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in client },
        endpointProbe: { _ in false }
      )

      await #expect(throws: DaemonControlError.daemonDidNotStart) {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(1))
      }

      #expect(client.readCallCount(.health) == 0)
    }
  }

  @Test("bootstrapClient shuts down the probe HTTP client after a WebSocket upgrade")
  func bootstrapClientShutsDownProbeHTTPClientAfterWebSocketUpgrade() async throws {
    try await withTempDaemonFixture(pid: UInt32(getpid())) { environment in
      let httpClient = RecordingHarnessClient()
      let webSocketClient = RecordingHarnessClient()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in httpClient },
        webSocketBootstrapper: { _ in webSocketClient }
      )

      let client = try await controller.bootstrapClient()

      #expect(client as AnyObject === webSocketClient as AnyObject)
      #expect(httpClient.readCallCount(.health) == 1)
      #expect(httpClient.shutdownCallCount() == 1)
      #expect(webSocketClient.shutdownCallCount() == 0)
    }
  }

  @Test("auto transport bootstrap does not wait for a slow WebSocket upgrade")
  func autoTransportBootstrapDoesNotWaitForSlowWebSocketUpgrade() async throws {
    let httpClient = RecordingHarnessClient()
    let webSocketClient = RecordingHarnessClient()
    let controller = DaemonController(
      transportPreference: .auto,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      sessionFactory: { _ in httpClient },
      webSocketBootstrapper: { _ in
        try? await Task.sleep(for: .milliseconds(400))
        return webSocketClient
      }
    )
    let connection = HarnessMonitorConnection(
      endpoint: try #require(URL(string: "http://127.0.0.1:65535")),
      token: "test-token"
    )
    let clock = ContinuousClock()
    let start = clock.now

    let client = try await controller.bootstrap(connection: connection)

    let elapsed = start.duration(to: clock.now)
    #expect(client as AnyObject === httpClient as AnyObject)
    #expect(elapsed < .milliseconds(200))
    #expect(httpClient.readCallCount(.health) == 1)
    #expect(httpClient.shutdownCallCount() == 0)
    #expect(webSocketClient.shutdownCallCount() == 0)
  }

  @Test("awaitManifestWarmUp waits for managed manifest rewrite while the stale pid is still alive")
  func awaitManifestWarmUpWaitsForManagedManifestRewriteWhilePidIsAlive() async throws {
    try await withTempDaemonFixture(pid: UInt32(getpid())) { environment in
      let client = PreviewHarnessClient()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in client },
        endpointProbe: { endpoint in
          endpoint.port == 65_533
        }
      )

      Task.detached {
        try? await Task.sleep(for: .milliseconds(150))
        try? rewriteTempDaemonFixtureManifest(
          environment: environment,
          pid: 1_234,
          endpoint: "http://127.0.0.1:65533",
          startedAt: "2026-04-11T12:01:00Z"
        )
      }

      let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))
      #expect(bootstrappedClient as AnyObject === client as AnyObject)
    }
  }

  @Test("awaitManifestWarmUp caps managed stale manifest waits before the full timeout")
  func awaitManifestWarmUpCapsManagedStaleManifestWaits() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        endpointProbe: { _ in false },
        managedStaleManifestGracePeriod: .milliseconds(200)
      )
      let clock = ContinuousClock()
      let start = clock.now

      await #expect(throws: DaemonControlError.daemonDidNotStart) {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(2))
      }

      let elapsed = start.duration(to: clock.now)
      #expect(elapsed < .seconds(1))
    }
  }

  @Test("awaitManifestWarmUp rejects managed daemon version mismatches promptly")
  func awaitManifestWarmUpRejectsManagedDaemonVersionMismatchPromptly() async throws {
    try await withTempDaemonFixture(
      pid: UInt32(getpid()),
      version: "20.6.17"
    ) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        expectedManagedDaemonVersion: { "20.6.19" }
      )
      let clock = ContinuousClock()
      let start = clock.now

      await #expect(
        throws: DaemonControlError.managedDaemonVersionMismatch(
          expected: "20.6.19",
          actual: "20.6.17"
        )
      ) {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(5))
      }

      let elapsed = start.duration(to: clock.now)
      #expect(elapsed < .seconds(1))
    }
  }

  @Test("warm-up lifecycle messages keep related context in a single event")
  func warmUpLifecycleMessagesKeepRelatedContextInSingleEvent() {
    let endpoint = "http://127.0.0.1:54593"
    let manifestPath = "/tmp/harness-monitor/daemon/manifest.json"

    #expect(
      DaemonController.warmUpObservedManifestMessage(pid: 92_673, endpoint: endpoint)
        == "Warm-up observed manifest pid=92673 endpoint=\(endpoint)"
    )
    #expect(
      DaemonController.warmUpStaleManifestMessage(path: manifestPath, endpoint: endpoint)
        == "Warm-up found stale daemon manifest at \(manifestPath) endpoint=\(endpoint)"
    )
    #expect(
      DaemonController.warmUpDeadManagedManifestMessage(pid: 92_673, path: manifestPath)
        == "Warm-up detected dead managed daemon pid 92673 stale-manifest=\(manifestPath)"
    )
    #expect(
      DaemonController.warmUpManagedStaleManifestTimeoutMessage(
        path: manifestPath,
        gracePeriod: "5.0 seconds"
      )
        == "Warm-up aborting managed stale manifest wait at \(manifestPath) "
        + "grace-period=5.0 seconds"
    )
  }

}
