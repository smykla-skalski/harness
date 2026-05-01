import Darwin
import Foundation
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import Testing

@testable import HarnessMonitorKit

/// Locks down the default-on startup and orchestration contract for the MCP
/// accessibility registry host.
@MainActor
@Suite("HarnessMonitor MCP contract")
struct HarnessMonitorMCPContractTests {
  // MARK: - Default-on contract

  @Test("Default value constant is true")
  func defaultValueConstantIsTrue() {
    #expect(HarnessMonitorMCPPreferencesDefaults.registryHostEnabledDefault == true)
  }

  @Test("Registration defaults dictionary enables the registry host")
  func registrationDefaultsDictionaryEnablesTheRegistryHost() {
    let defaults = HarnessMonitorMCPPreferencesDefaults.registrationDefaults()
    let value = defaults[HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey] as? Bool
    #expect(value == true)
  }

  @Test("Startup registration defaults helper includes the MCP key")
  func startupRegistrationDefaultsIncludesMCPKey() {
    let values = HarnessMonitorStartupRegistrationDefaults.values()
    let value = values[HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey] as? Bool
    #expect(value == true)
  }

  // MARK: - Startup orchestration

  @MainActor
  @Test("enabled startup success converges to healthy")
  func enabledStartupSuccessConvergesToHealthy() async throws {
    let defaults = try isolatedDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let service = StubMCPService()
    service.nextEnabledRuntimeState = .healthy(socketPath: "/tmp/mcp.sock")
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      forceEnable: { false }
    )

    controller.start()
    await Task.yield()

    #expect(service.recordedEnabledStates == [true])
    #expect(controller.runtimeState == .healthy(socketPath: "/tmp/mcp.sock"))

    await controller.stop()
  }

  @MainActor
  @Test("disabled startup stays disabled and does not start the service")
  func disabledStartupStaysDisabled() async throws {
    let defaults = try isolatedDefaults()
    let enabledKey = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    defaults.defaults.set(false, forKey: enabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let service = StubMCPService()
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      forceEnable: { false }
    )

    controller.start()
    await Task.yield()

    #expect(service.recordedEnabledStates == [false])
    #expect(controller.runtimeState == .disabled)

    await controller.stop()
  }

  @MainActor
  @Test("enabled startup failure retains the degraded reason")
  func enabledStartupFailureRetainsTheDegradedReason() async throws {
    let defaults = try isolatedDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let degradedState = HarnessMonitorMCPRuntimeState.degraded(
      socketPath: "/tmp/mcp.sock",
      reason: "listener bind failed"
    )
    let service = StubMCPService()
    service.nextEnabledRuntimeState = degradedState
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      forceEnable: { false }
    )

    controller.start()
    await Task.yield()

    #expect(controller.runtimeState == degradedState)

    await controller.stop()
  }

  @MainActor
  @Test("startup controller publishes starting before settling healthy")
  func startupControllerPublishesStartingBeforeSettlingHealthy() async throws {
    let defaults = try isolatedDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let service = BlockingMCPService()
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: NotificationCenter(),
      forceEnable: { false }
    )

    controller.start()
    await service.waitForEnableAttempt()

    #expect(controller.runtimeState == .starting(socketPath: nil))

    service.finishEnable(with: .healthy(socketPath: "/tmp/mcp.sock"))
    await Task.yield()

    #expect(controller.runtimeState == .healthy(socketPath: "/tmp/mcp.sock"))

    await controller.stop()
  }

  @MainActor
  @Test("later preference changes disable and then re-enable through the owner")
  func laterPreferenceChangesDisableAndReenableThroughTheOwner() async throws {
    let defaults = try isolatedDefaults()
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    defer { defaults.defaults.removePersistentDomain(forName: defaults.suiteName) }

    let notificationCenter = NotificationCenter()
    let service = StubMCPService()
    service.nextEnabledRuntimeState = .healthy(socketPath: "/tmp/mcp.sock")
    let controller = HarnessMonitorMCPStartupController(
      service: service,
      defaults: defaults.defaults,
      notificationCenter: notificationCenter,
      forceEnable: { false }
    )

    controller.start()
    await Task.yield()

    let enabledKey = HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    defaults.defaults.set(false, forKey: enabledKey)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    try await awaitRuntimeState(
      controller,
      equals: .disabled,
      timeoutSeconds: 1
    )

    #expect(controller.runtimeState == .disabled)

    service.nextEnabledRuntimeState = .healthy(socketPath: "/tmp/mcp.sock")
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await Task.yield()

    #expect(service.recordedEnabledStates == [true, false, true])
    #expect(controller.runtimeState == .healthy(socketPath: "/tmp/mcp.sock"))

    await controller.stop()
  }

  private func awaitRuntimeState(
    _ controller: HarnessMonitorMCPStartupController,
    equals expected: HarnessMonitorMCPRuntimeState,
    timeoutSeconds: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      if controller.runtimeState == expected {
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(controller.runtimeState == expected)
  }
}

@MainActor
private final class StubMCPService: HarnessMonitorMCPStartupControlling {
  var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  var nextEnabledRuntimeState: HarnessMonitorMCPRuntimeState = .healthy(socketPath: "/tmp/mcp.sock")
  private(set) var recordedEnabledStates: [Bool] = []

  func setEnabled(_ enabled: Bool) async {
    recordedEnabledStates.append(enabled)
    runtimeState = enabled ? nextEnabledRuntimeState : .disabled
  }

  func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState {
    runtimeState
  }
}

@MainActor
private final class BlockingMCPService: HarnessMonitorMCPStartupControlling {
  var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  private(set) var recordedEnabledStates: [Bool] = []

  private var enableAttemptWaiters: [CheckedContinuation<Void, Never>] = []
  private var enableFinishedContinuation: CheckedContinuation<HarnessMonitorMCPRuntimeState, Never>?
  private var enableAttemptStarted = false

  func setEnabled(_ enabled: Bool) async {
    guard enabled else {
      recordedEnabledStates.append(false)
      runtimeState = .disabled
      return
    }

    runtimeState = .starting(socketPath: nil)
    let terminalState = await withCheckedContinuation { continuation in
      enableAttemptStarted = true
      enableFinishedContinuation = continuation
      let waiters = enableAttemptWaiters
      enableAttemptWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
    }
    recordedEnabledStates.append(true)
    runtimeState = terminalState
  }

  func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState {
    runtimeState
  }

  func waitForEnableAttempt() async {
    if enableAttemptStarted {
      return
    }
    await withCheckedContinuation { continuation in
      enableAttemptWaiters.append(continuation)
    }
  }

  func finishEnable(with state: HarnessMonitorMCPRuntimeState) {
    enableFinishedContinuation?.resume(returning: state)
    enableFinishedContinuation = nil
  }
}

enum MCPContractTestError: Error, CustomStringConvertible {
  case socketNeverAppeared(String)
  case clientSocketFailed(Int32)
  case connectFailed(Int32)
  case sendFailed(Int32)
  case recvFailed(Int32)
  case invalidUTF8Response

  var description: String {
    switch self {
    case .socketNeverAppeared(let path):
      "socket never appeared at \(path)"
    case .clientSocketFailed(let code):
      "socket() failed: \(String(cString: strerror(code)))"
    case .connectFailed(let code):
      "connect() failed: \(String(cString: strerror(code)))"
    case .sendFailed(let code):
      "send() failed: \(String(cString: strerror(code)))"
    case .recvFailed(let code):
      "recv() failed: \(String(cString: strerror(code)))"
    case .invalidUTF8Response:
      "received invalid UTF-8 from the registry socket"
    }
  }
}
