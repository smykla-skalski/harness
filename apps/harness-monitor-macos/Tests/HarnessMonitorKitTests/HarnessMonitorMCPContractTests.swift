import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit
import HarnessMonitorUIPreviewable

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
    defaults.defaults.set(false, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
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

    defaults.defaults.set(false, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await Task.yield()

    #expect(controller.runtimeState == .disabled)

    service.nextEnabledRuntimeState = .healthy(socketPath: "/tmp/mcp.sock")
    defaults.defaults.set(true, forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey)
    notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults.defaults)
    await Task.yield()

    #expect(service.recordedEnabledStates == [true, false, true])
    #expect(controller.runtimeState == .healthy(socketPath: "/tmp/mcp.sock"))

    await controller.stop()
  }

  // MARK: - Real service behavior

  @Test("disabled reconciliation removes a stale socket path left behind by a dead process")
  func disabledReconciliationRemovesStaleSocketPath() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    FileManager.default.createFile(atPath: socketURL.path, contents: Data("stale".utf8))
    #expect(FileManager.default.fileExists(atPath: socketURL.path))

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL }
    )

    await service.setEnabled(false)

    #expect(FileManager.default.fileExists(atPath: socketURL.path) == false)
    #expect(service.runtimeState == .disabled)
  }

  @Test("enabled reconciliation binds a healthy registry socket")
  func enabledReconciliationBindsHealthyRegistrySocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL }
    )
    await service.setEnabled(true)
    defer { Task { await service.setEnabled(false) } }

    try await waitForSocket(at: socketURL.path, timeout: 2)
    let response = try sendLine("{\"id\":1,\"op\":\"ping\"}", toSocketAt: socketURL.path)

    #expect(response.contains("\"ok\":true"))
    #expect(service.runtimeState == .healthy(socketPath: socketURL.path))
  }

  @Test("real service degrades when the socket path cannot be resolved")
  func realServiceDegradesWhenSocketPathCannotBeResolved() async {
    let service = HarnessMonitorMCPAccessibilityService(socketPathResolver: { nil })

    await service.setEnabled(true)

    #expect(
      service.runtimeState
        == .degraded(socketPath: nil, reason: "cannot resolve app-group container")
    )
  }

  // MARK: - Helpers

  private func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "io.harnessmonitor.tests.mcp.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.register(defaults: HarnessMonitorMCPPreferencesDefaults.registrationDefaults())
    return (defaults, suiteName)
  }

  private func waitForSocket(at path: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while FileManager.default.fileExists(atPath: path) == false {
      if Date() > deadline {
        throw MCPContractTestError.socketNeverAppeared(path)
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func sendLine(_ line: String, toSocketAt path: String) throws -> String {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MCPContractTestError.clientSocketFailed(errno) }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    withUnsafeMutableBytes(of: &addr.sun_path) { pointer in
      pointer.baseAddress?.copyMemory(from: pathBytes, byteCount: pathBytes.count)
    }
    let connectResult = withUnsafePointer(to: &addr) { addrPointer -> Int32 in
      addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if connectResult != 0 { throw MCPContractTestError.connectFailed(errno) }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((line + "\n").utf8)
    let sent = payload.withUnsafeBytes { buffer in
      Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
    }
    if sent < 0 { throw MCPContractTestError.sendFailed(errno) }

    var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    let received = scratch.withUnsafeMutableBufferPointer { buffer in
      Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
    }
    if received < 0 { throw MCPContractTestError.recvFailed(errno) }
    guard let response = String(bytes: scratch.prefix(received), encoding: .utf8) else {
      throw MCPContractTestError.invalidUTF8Response
    }
    return response
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
}

@MainActor
private final class BlockingMCPService: HarnessMonitorMCPStartupControlling {
  var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  private(set) var recordedEnabledStates: [Bool] = []

  private var enableAttemptWaiters: [CheckedContinuation<Void, Never>] = []
  private var enableFinishedContinuation:
    CheckedContinuation<HarnessMonitorMCPRuntimeState, Never>?
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

private enum MCPContractTestError: Error, CustomStringConvertible {
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
