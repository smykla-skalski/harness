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
    "awaitManifestWarmUp does not issue a stale HTTP bootstrap after a managed dead pid is detected")
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

  @Test("awaitManifestWarmUp refreshes the managed launch agent before probing when the bundled helper changed")
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
            helperPath:
              "/Users/example/Library/Developer/Xcode/DerivedData/HarnessMonitor/Build/Products/Debug/Harness Monitor.app/Contents/Helpers/harness",
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
      helperPath:
        "/Users/example/Library/Developer/Xcode/DerivedData/HarnessMonitor/Build/Products/Debug/Harness Monitor.app/Contents/Helpers/harness",
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

    try await withTempDaemonFixture(
      pid: UInt32(getpid()),
      endpoint: "http://127.0.0.1:65534",
      binaryStamp: staleManifestStamp
    ) { environment in
      let client = PreviewHarnessClient()
      let liveEndpoint = "http://127.0.0.1:65533"
      try writeManagedLaunchAgentBundleStampFixture(currentStamp, environment: environment)
      let manager = HookedLaunchAgentManager(
        state: .enabled,
        onRegister: {
          try rewriteTempDaemonFixtureManifest(
            environment: environment,
            pid: UInt32(getpid()),
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

  @Test("awaitManifestWarmUp reports external offline when no manifest appears")
  func awaitManifestWarmUpReportsExternalOfflineWhenManifestMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
    try FileManager.default.createDirectory(at: daemonHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let controller = DaemonController(
      environment: environment,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .external
    )

    do {
      _ = try await controller.awaitManifestWarmUp(timeout: .milliseconds(50))
      Issue.record("Expected externalDaemonOffline")
    } catch let error as DaemonControlError {
      guard case .externalDaemonOffline(let manifestPath) = error else {
        Issue.record("Expected externalDaemonOffline, got \(error)")
        return
      }
      #expect(manifestPath == HarnessMonitorPaths.manifestURL(using: environment).path)
    } catch {
      Issue.record("Expected DaemonControlError, got \(error)")
    }
  }

  @Test("awaitManifestWarmUp reports manifestMissing when no managed manifest appears")
  func awaitManifestWarmUpReportsManagedManifestMissing() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
    try FileManager.default.createDirectory(at: daemonHome, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
      homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
    )
    let controller = DaemonController(
      environment: environment,
      launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
      ownership: .managed
    )

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: .milliseconds(50))
    }
  }

  @Test("bootstrapClient rejects managed manifests with non-loopback endpoints")
  func bootstrapClientRejectsNonLoopbackManagedEndpoint() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      endpoint: "http://example.com:65534"
    ) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in PreviewHarnessClient() }
      )

      do {
        _ = try await controller.bootstrapClient()
        Issue.record("Expected invalidManifest")
      } catch let error as DaemonControlError {
        guard case .invalidManifest(let reason) = error else {
          Issue.record("Expected invalidManifest, got \(error)")
          return
        }
        #expect(reason.contains("loopback"))
      } catch {
        Issue.record("Expected DaemonControlError, got \(error)")
      }
    }
  }

  @Test("bootstrapClient rejects symlinked token paths")
  func bootstrapClientRejectsSymlinkedTokenPath() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      tokenPathFactory: { daemonRoot in
        let outsideToken = daemonRoot.deletingLastPathComponent()
          .appendingPathComponent("outside-auth-token")
        try writeTokenFixture(to: outsideToken)
        let symlinkURL = daemonRoot.appendingPathComponent("auth-token-link")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideToken)
        return symlinkURL
      },
      perform: { environment in
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
          ownership: .managed,
          sessionFactory: { _ in PreviewHarnessClient() }
        )

        do {
          _ = try await controller.bootstrapClient()
          Issue.record("Expected invalidManifest")
        } catch let error as DaemonControlError {
          guard case .invalidManifest(let reason) = error else {
            Issue.record("Expected invalidManifest, got \(error)")
            return
          }
          #expect(reason.contains("symlink"))
        } catch {
          Issue.record("Expected DaemonControlError, got \(error)")
        }
      }
    )
  }

  @Test("bootstrapClient rejects group-readable token files")
  func bootstrapClientRejectsPermissiveTokenPermissions() async throws {
    try await withTempDaemonFixture(
      pid: 1_234,
      tokenPathFactory: { daemonRoot in
        let tokenURL = daemonRoot.appendingPathComponent("auth-token")
        try writeTokenFixture(to: tokenURL, permissions: 0o644)
        return tokenURL
      },
      perform: { environment in
        let controller = DaemonController(
          environment: environment,
          launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
          ownership: .managed,
          sessionFactory: { _ in PreviewHarnessClient() }
        )

        do {
          _ = try await controller.bootstrapClient()
          Issue.record("Expected invalidManifest")
        } catch let error as DaemonControlError {
          guard case .invalidManifest(let reason) = error else {
            Issue.record("Expected invalidManifest, got \(error)")
            return
          }
          #expect(reason.contains("permissions"))
        } catch {
          Issue.record("Expected DaemonControlError, got \(error)")
        }
      }
    )
  }

  @Test("Installing launch agent registers the bundled service")
  func installingLaunchAgentRegistersBundledService() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    let result = try await controller.installLaunchAgent()

    #expect(result == "launch agent installed")
    #expect(manager.registerCallCount == 1)
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.state == .enabled)
  }

  @Test("Removing launch agent unregisters enabled service")
  func removingLaunchAgentUnregistersEnabledService() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    let result = try await controller.removeLaunchAgent()

    #expect(result == "launch agent removed")
    #expect(manager.registerCallCount == 0)
    #expect(manager.unregisterCallCount == 1)
    #expect(manager.state == .notRegistered)
  }

  @Test("Approval-required launch agent does not re-register")
  func approvalRequiredLaunchAgentDoesNotRegister() async throws {
    let manager = RecordingLaunchAgentManager(state: .requiresApproval)
    let controller = DaemonController(launchAgentManager: manager)

    await #expect(throws: DaemonControlError.self) {
      _ = try await controller.installLaunchAgent()
    }
    #expect(manager.registerCallCount == 0)
  }

  @Test("registerLaunchAgent returns enabled after registering notRegistered agent")
  func registerLaunchAgentReturnsEnabledState() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    let state = try await controller.registerLaunchAgent()

    #expect(state == .enabled)
    #expect(manager.registerCallCount == 1)
  }

  @Test("registerLaunchAgent surfaces requiresApproval when SMAppService needs consent")
  func registerLaunchAgentSurfacesApprovalRequired() async throws {
    let manager = RecordingLaunchAgentManager(
      state: .notRegistered,
      registerResult: .requiresApproval
    )
    let controller = DaemonController(launchAgentManager: manager)

    let state = try await controller.registerLaunchAgent()

    #expect(state == .requiresApproval)
    #expect(manager.registerCallCount == 1)
  }

  @Test("awaitLaunchAgentState throws daemonDidNotStart when state never matches")
  func awaitLaunchAgentStateTimesOut() async throws {
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let controller = DaemonController(launchAgentManager: manager)

    await #expect(throws: DaemonControlError.daemonDidNotStart) {
      try await controller.awaitLaunchAgentState(
        .enabled,
        timeout: .milliseconds(50)
      )
    }
  }

  @Test("awaitLaunchAgentState returns immediately when state already matches")
  func awaitLaunchAgentStateReturnsWhenReady() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    try await controller.awaitLaunchAgentState(
      .enabled,
      timeout: .milliseconds(50)
    )
  }

  @Test("launchAgentSnapshot mirrors current registration state")
  func launchAgentSnapshotMirrorsRegistrationState() async throws {
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let controller = DaemonController(launchAgentManager: manager)

    let enabledSnapshot = await controller.launchAgentSnapshot()
    #expect(enabledSnapshot.installed == true)
    #expect(enabledSnapshot.loaded == true)

    try manager.unregister()

    let offlineSnapshot = await controller.launchAgentSnapshot()
    #expect(offlineSnapshot.installed == false)
    #expect(offlineSnapshot.loaded == false)
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
