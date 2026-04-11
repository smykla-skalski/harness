import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon controller service management")
struct DaemonControllerTests {
  @Test("awaitManifestWarmUp returns stale manifest immediately for external daemon when pid is dead")
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

  @Test("awaitManifestWarmUp returns daemonDidNotStart immediately for managed daemon when pid is dead")
  func awaitManifestWarmUpReturnsManagedStaleManifestImmediately() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        endpointProbe: { _ in false }
      )

      await #expect(throws: DaemonControlError.daemonDidNotStart) {
        _ = try await controller.awaitManifestWarmUp(timeout: .seconds(5))
      }
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
  perform: (HarnessMonitorEnvironment) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("daemon-controller-tests-\(UUID().uuidString)", isDirectory: true)
  let daemonHome = root.appendingPathComponent("data-home", isDirectory: true)
  let daemonRoot = daemonHome
    .appendingPathComponent("harness", isDirectory: true)
    .appendingPathComponent("daemon", isDirectory: true)
  try FileManager.default.createDirectory(at: daemonRoot, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let tokenPath = daemonRoot.appendingPathComponent("auth-token")
  try "test-token".write(to: tokenPath, atomically: true, encoding: .utf8)

  let manifest = DaemonManifest(
    version: "19.4.1",
    pid: Int(pid),
    endpoint: "http://127.0.0.1:65534",
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
