import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon controller service management")
struct DaemonControllerTests {
  @Test("Start command uses daemon sandbox mode")
  func startCommandUsesDaemonSandboxMode() {
    #expect(DaemonController.daemonServeArguments.contains("--sandboxed"))
  }

  @Test("Process environment pins app group daemon root")
  func processEnvironmentPinsAppGroupDaemonRoot() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    let environment = HarnessMonitorEnvironment(values: [:], homeDirectory: home)

    let values = DaemonController.daemonProcessEnvironment(
      base: [
        HarnessMonitorAppGroup.environmentKey: "",
        "HARNESS_SANDBOXED": "0",
      ],
      environment: environment
    )

    #expect(values[HarnessMonitorAppGroup.environmentKey] == HarnessMonitorAppGroup.identifier)
    #expect(values["HARNESS_SANDBOXED"] == "1")
    #expect(
      values[HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey]
        == HarnessMonitorPaths.dataRoot(using: environment).path
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
