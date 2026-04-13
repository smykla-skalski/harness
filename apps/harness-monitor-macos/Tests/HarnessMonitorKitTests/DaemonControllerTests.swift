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

private func withTempDaemonFixture(
  pid: UInt32,
  endpoint: String = "http://127.0.0.1:65534",
  tokenPathFactory: ((URL) throws -> URL)? = nil,
  perform: (HarnessMonitorEnvironment) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
  let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
  let daemonRoot =
    daemonHome
    .appendingPathComponent("harness", isDirectory: true)
    .appendingPathComponent("daemon", isDirectory: true)
  try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let tokenPath: URL
  if let tokenPathFactory {
    tokenPath = try tokenPathFactory(daemonRoot)
  } else {
    tokenPath = daemonRoot.appendingPathComponent("auth-token")
    try writeTokenFixture(to: tokenPath)
  }

  let manifest = DaemonManifest(
    version: "19.4.1",
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: "2026-04-11T12:00:00Z",
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest()
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let manifestData = try encoder.encode(manifest)
  try manifestData.write(to: daemonRoot.appendingPathComponent("manifest.json"))

  let environment = HarnessMonitorEnvironment(
    values: [HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonHome.path],
    homeDirectory: URL(fileURLWithPath: "/Users/example", isDirectory: true)
  )
  try await perform(environment)
}

private func writeTokenFixture(
  _ value: String = "test-token",
  to url: URL,
  permissions: Int = 0o600
) throws {
  try value.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

private func rewriteTempDaemonFixtureManifest(
  environment: HarnessMonitorEnvironment,
  pid: UInt32,
  endpoint: String,
  startedAt: String
) throws {
  let tokenPath = HarnessMonitorPaths.authTokenURL(using: environment)
  let manifest = DaemonManifest(
    version: "19.4.1",
    pid: Int(pid),
    endpoint: endpoint,
    startedAt: startedAt,
    tokenPath: tokenPath.path,
    sandboxed: true,
    hostBridge: HostBridgeManifest()
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  encoder.keyEncodingStrategy = .convertToSnakeCase
  let manifestData = try encoder.encode(manifest)
  try manifestData.write(to: HarnessMonitorPaths.manifestURL(using: environment))
}

private final class RecordingLaunchAgentManager: DaemonLaunchAgentManaging, @unchecked Sendable {
  private let lock = NSLock()
  private var protectedState: DaemonLaunchAgentRegistrationState
  private let registerResult: DaemonLaunchAgentRegistrationState
  private var protectedRegisterCallCount = 0
  private var protectedUnregisterCallCount = 0

  init(
    state: DaemonLaunchAgentRegistrationState,
    registerResult: DaemonLaunchAgentRegistrationState = .enabled
  ) {
    self.protectedState = state
    self.registerResult = registerResult
  }

  var state: DaemonLaunchAgentRegistrationState {
    lock.withLock { protectedState }
  }

  var registerCallCount: Int {
    lock.withLock { protectedRegisterCallCount }
  }

  var unregisterCallCount: Int {
    lock.withLock { protectedUnregisterCallCount }
  }

  func registrationState() -> DaemonLaunchAgentRegistrationState {
    lock.withLock { protectedState }
  }

  func register() throws {
    lock.withLock {
      protectedRegisterCallCount += 1
      protectedState = registerResult
    }
  }

  func unregister() throws {
    lock.withLock {
      protectedUnregisterCallCount += 1
      protectedState = .notRegistered
    }
  }
}
