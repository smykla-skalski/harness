import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

private let managedLaunchAgentHelperPathFixture =
  "/Users/example/Library/Developer/Xcode/DerivedData/HarnessMonitor/Build/Products/Debug/"
  + "Harness Monitor.app/Contents/Helpers/harness"

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

  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent before probing when the bundled helper changed"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentBeforeProbingWhenBundledHelperChanged()
    async throws
  {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let client = PreviewHarnessClient()
      let manifestRewritePID = UInt32(getpid())
      let liveEndpoint = "http://127.0.0.1:65533"
      try writeManagedLaunchAgentBundleStampFixture(
        ManagedLaunchAgentBundleStampFixture(
          helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
          deviceIdentifier: 41,
          inode: 84,
          fileSize: 16_384,
          modificationTimeIntervalSince1970: 1_713_000_000
        ),
        environment: environment
      )
      let manager = HookedLaunchAgentManager(
        state: .enabled,
        onRegister: {
          try rewriteTempDaemonFixtureManifest(
            environment: environment,
            pid: manifestRewritePID,
            endpoint: liveEndpoint,
            startedAt: "2026-04-14T13:22:13Z"
          )
        }
      )
      let probedEndpoints = EndpointProbeRecorder()
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: manager,
        ownership: .managed,
        sessionFactory: { _ in client },
        endpointProbe: { endpoint in
          await probedEndpoints.record(endpoint.absoluteString)
          return endpoint.absoluteString == liveEndpoint
        },
        managedLaunchAgentCurrentBundleStamp: {
          ManagedLaunchAgentBundleStamp(
            helperPath: managedLaunchAgentHelperPathFixture,
            deviceIdentifier: 99,
            inode: 128,
            fileSize: 32_768,
            modificationTimeIntervalSince1970: 1_714_000_000
          )
        }
      )

      let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

      #expect(bootstrappedClient as AnyObject === client as AnyObject)
      #expect(manager.unregisterCallCount == 1)
      #expect(manager.registerCallCount == 1)
      #expect(await probedEndpoints.values() == [liveEndpoint])
    }
  }

  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent before trusting a live manifest from a replaced helper"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentBeforeTrustingMismatchedLiveHelperIdentity()
    async throws
  {
    let currentStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: managedLaunchAgentHelperPathFixture,
      deviceIdentifier: 99,
      inode: 128,
      fileSize: 32_768,
      modificationTimeIntervalSince1970: 1_714_000_000
    )
    let staleManifestStamp = DaemonBinaryStampFixture(
      helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
      deviceIdentifier: 41,
      inode: 84,
      fileSize: 16_384,
      modificationTimeIntervalSince1970: 1_713_000_000
    )
    let liveEndpoint = "http://127.0.0.1:65533"

    try await withSignalIgnoringSleepProcessPID { livePID in
      try await withTempDaemonFixture(
        pid: livePID,
        endpoint: liveEndpoint,
        binaryStamp: staleManifestStamp
      ) { environment in
        let client = PreviewHarnessClient()
        try writeManagedLaunchAgentBundleStampFixture(currentStamp, environment: environment)
        let manager = HookedLaunchAgentManager(
          state: .enabled,
          onRegister: {
            try rewriteTempDaemonFixtureManifest(
              environment: environment,
              pid: livePID,
              endpoint: liveEndpoint,
              startedAt: "2026-04-14T13:22:13Z",
              binaryStamp: DaemonBinaryStampFixture(
                helperPath: currentStamp.helperPath,
                deviceIdentifier: currentStamp.deviceIdentifier,
                inode: currentStamp.inode,
                fileSize: currentStamp.fileSize,
                modificationTimeIntervalSince1970: currentStamp.modificationTimeIntervalSince1970
              )
            )
          }
        )
        let probedEndpoints = EndpointProbeRecorder()
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: manager,
          ownership: .managed,
          sessionFactory: { _ in client },
          endpointProbe: { endpoint in
            await probedEndpoints.record(endpoint.absoluteString)
            return endpoint.absoluteString == liveEndpoint
          },
          managedLaunchAgentCurrentBundleStamp: {
            ManagedLaunchAgentBundleStamp(
              helperPath: currentStamp.helperPath,
              deviceIdentifier: currentStamp.deviceIdentifier,
              inode: currentStamp.inode,
              fileSize: currentStamp.fileSize,
              modificationTimeIntervalSince1970: currentStamp.modificationTimeIntervalSince1970
            )
          }
        )

        let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

        #expect(bootstrappedClient as AnyObject === client as AnyObject)
        #expect(manager.unregisterCallCount == 1)
        #expect(manager.registerCallCount == 1)
        #expect(await probedEndpoints.values() == [liveEndpoint])
      }
    }
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

  @Test(
    "awaitManifestWarmUp refreshes the managed launch agent and waits for version-mismatch manifest rewrite"
  )
  func awaitManifestWarmUpRefreshesManagedLaunchAgentAndWaitsForVersionMismatchRewrite()
    async throws
  {
    let currentStamp = ManagedLaunchAgentBundleStampFixture(
      helperPath: managedLaunchAgentHelperPathFixture,
      deviceIdentifier: 99,
      inode: 128,
      fileSize: 32_768,
      modificationTimeIntervalSince1970: 1_714_000_000
    )
    let staleEndpoint = "http://127.0.0.1:65534"
    let liveEndpoint = "http://127.0.0.1:65533"
    let expectedVersion = "23.1.1"

    try await withSignalIgnoringSleepProcessPID { stalePID in
      try await withTempDaemonFixture(
        pid: stalePID,
        version: "23.1.0",
        endpoint: staleEndpoint
      ) { environment in
        let client = PreviewHarnessClient()
        try writeManagedLaunchAgentBundleStampFixture(currentStamp, environment: environment)
        let manager = HookedLaunchAgentManager(
          state: .enabled,
          onRegister: {
            Task.detached {
              try? await Task.sleep(for: .milliseconds(150))
              try? rewriteTempDaemonFixtureManifest(
                environment: environment,
                pid: UInt32(getpid()),
                version: expectedVersion,
                endpoint: liveEndpoint,
                startedAt: "2026-04-17T11:03:00Z",
                binaryStamp: DaemonBinaryStampFixture(
                  helperPath: currentStamp.helperPath,
                  deviceIdentifier: currentStamp.deviceIdentifier,
                  inode: currentStamp.inode,
                  fileSize: currentStamp.fileSize,
                  modificationTimeIntervalSince1970:
                    currentStamp.modificationTimeIntervalSince1970
                )
              )
            }
          }
        )
        let probedEndpoints = EndpointProbeRecorder()
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: manager,
          ownership: .managed,
          sessionFactory: { _ in client },
          endpointProbe: { endpoint in
            await probedEndpoints.record(endpoint.absoluteString)
            return endpoint.absoluteString == liveEndpoint
          },
          expectedManagedDaemonVersion: { expectedVersion },
          managedLaunchAgentCurrentBundleStamp: {
            ManagedLaunchAgentBundleStamp(
              helperPath: currentStamp.helperPath,
              deviceIdentifier: currentStamp.deviceIdentifier,
              inode: currentStamp.inode,
              fileSize: currentStamp.fileSize,
              modificationTimeIntervalSince1970:
                currentStamp.modificationTimeIntervalSince1970
            )
          }
        )

        let bootstrappedClient = try await controller.awaitManifestWarmUp(timeout: .seconds(1))

        #expect(bootstrappedClient as AnyObject === client as AnyObject)
        #expect(manager.unregisterCallCount == 1)
        #expect(manager.registerCallCount == 1)
        #expect(await probedEndpoints.values() == [liveEndpoint])
      }
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

private struct ManagedLaunchAgentBundleStampFixture: Codable {
  let helperPath: String
  let deviceIdentifier: UInt64
  let inode: UInt64
  let fileSize: UInt64
  let modificationTimeIntervalSince1970: Double
}

private actor EndpointProbeRecorder {
  private var endpoints: [String] = []

  func record(_ endpoint: String) {
    endpoints.append(endpoint)
  }

  func values() -> [String] {
    endpoints
  }
}

private func writeManagedLaunchAgentBundleStampFixture(
  _ stamp: ManagedLaunchAgentBundleStampFixture,
  environment: HarnessMonitorEnvironment
) throws {
  let url = HarnessMonitorPaths.daemonRoot(using: environment)
    .appendingPathComponent("managed-launch-agent-bundle-stamp.json")
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(stamp)
  try data.write(to: url)
}
