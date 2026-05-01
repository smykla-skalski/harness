import Darwin
import Foundation
import HarnessMonitorRegistry
import HarnessMonitorUIPreviewable
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorMCPContractTests {
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

  @Test("enabled reconciliation reuses a compatible registry socket and forwards local snapshots")
  func enabledReconciliationReusesCompatibleRegistrySocket() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let hostService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })
    let reusedService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })

    await hostService.setEnabled(true)
    defer {
      Task {
        await reusedService.setEnabled(false)
        await hostService.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await hostService.registry.registerElement(
      RegistryElement(
        identifier: "host.refresh",
        kind: .button,
        frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
        windowID: 10
      )
    )

    await reusedService.setEnabled(true)
    await reusedService.registry.registerElement(
      RegistryElement(
        identifier: "client.refresh",
        kind: .button,
        frame: RegistryRect(x: 40, y: 60, width: 24, height: 24),
        windowID: 20
      )
    )

    try await waitForSocketResponse(at: socketURL.path, timeout: 2) { response in
      response.contains("\"identifier\":\"host.refresh\"")
        && response.contains("\"identifier\":\"client.refresh\"")
    }

    #expect(reusedService.isRunning == false)
    #expect(reusedService.runtimeState == .healthy(socketPath: socketURL.path))
  }

  @Test("enabled reconciliation replaces an incompatible socket and old host reregisters")
  func enabledReconciliationReplacesIncompatibleSocketAndReregisters() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let legacyHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.31.0",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [.replacementNotice]
        )
      },
      startupProbeDelay: .milliseconds(20),
      startupProbeCount: 50
    )
    let replacementHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.32.0",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      },
      startupProbeDelay: .milliseconds(20),
      startupProbeCount: 50
    )

    await legacyHost.setEnabled(true)
    defer {
      Task {
        await legacyHost.setEnabled(false)
        await replacementHost.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await legacyHost.registry.registerElement(
      RegistryElement(
        identifier: "legacy.refresh",
        kind: .button,
        frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
        windowID: 10
      )
    )

    await replacementHost.setEnabled(true)
    await replacementHost.registry.registerElement(
      RegistryElement(
        identifier: "replacement.refresh",
        kind: .button,
        frame: RegistryRect(x: 40, y: 60, width: 24, height: 24),
        windowID: 20
      )
    )

    try await waitForSocketResponse(at: socketURL.path, timeout: 2) { response in
      response.contains("\"identifier\":\"legacy.refresh\"")
        && response.contains("\"identifier\":\"replacement.refresh\"")
    }

    #expect(replacementHost.isRunning == true)
    #expect(replacementHost.runtimeState == .healthy(socketPath: socketURL.path))
    #expect(legacyHost.isRunning == false)
  }

  @Test("enabled reconciliation rejects foreign bundle registry hosts")
  func enabledReconciliationRejectsForeignBundleRegistryHosts() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)
    let foreignHost = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.32.0",
          bundleIdentifier: "io.foreign.registry",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
    )
    let localService = HarnessMonitorMCPAccessibilityService(socketPathResolver: { socketURL })

    await foreignHost.setEnabled(true)
    defer {
      Task {
        await localService.setEnabled(false)
        await foreignHost.setEnabled(false)
      }
    }
    try await waitForSocket(at: socketURL.path, timeout: 2)

    await localService.setEnabled(true)

    #expect(localService.isRunning == false)
    guard case .degraded(let socketPath, let reason) = localService.runtimeState else {
      Issue.record("expected degraded runtime state, got \(localService.runtimeState)")
      return
    }
    #expect(socketPath == socketURL.path)
    #expect(reason.contains("io.foreign.registry"))
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

  @Test("late replacement delivery after disable does not resurrect remote mode")
  func lateReplacementDeliveryAfterDisableDoesNotResurrectRemoteMode() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let socketURL = root.appendingPathComponent("mcp.sock", isDirectory: false)

    let service = HarnessMonitorMCPAccessibilityService(
      socketPathResolver: { socketURL },
      pingInfoProvider: {
        PingResult(
          protocolVersion: registryProtocolVersion,
          appVersion: "30.31.2",
          bundleIdentifier: "io.harnessmonitor.app",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
    )
    let notice = RegistryReplacementNotice(
      socketPath: socketURL.path,
      protocolVersion: registryProtocolVersion,
      appVersion: "30.32.0",
      bundleIdentifier: "io.harnessmonitor.app",
      message: "replacement incoming"
    )

    let disposition = await service.handleReplacementNotice(notice)
    #expect(disposition.ack.applied == true)

    await service.setEnabled(false)
    if let onDelivered = disposition.onDelivered {
      await onDelivered()
    } else {
      Issue.record("expected replacement delivery callback")
    }

    #expect(service.runtimeState == .disabled)
    #expect(service.isRunning == false)
    #expect(await service.probeRuntimeState() == .disabled)
  }

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

  private func waitForSocketResponse(
    at path: String,
    timeout: TimeInterval,
    predicate: (String) -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let response = try? sendLine("{\"id\":5,\"op\":\"listElements\"}", toSocketAt: path),
        predicate(response)
      {
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let response = try sendLine("{\"id\":5,\"op\":\"listElements\"}", toSocketAt: path)
    #expect(predicate(response))
  }

  private func sendLine(_ line: String, toSocketAt path: String) throws -> String {
    let fd = try connectSocket(to: path)
    defer { Darwin.close(fd) }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((line + "\n").utf8)
    try sendAll(payload, on: fd)
    let responseData = try readLine(from: fd)
    guard let response = String(data: responseData, encoding: .utf8) else {
      throw MCPContractTestError.invalidUTF8Response
    }
    return response
  }

  private func connectSocket(to path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw MCPContractTestError.clientSocketFailed(errno) }

    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(
      fd,
      SOL_SOCKET,
      SO_NOSIGPIPE,
      &noSigPipe,
      socklen_t(MemoryLayout<Int32>.size)
    )
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
    if connectResult != 0 {
      Darwin.close(fd)
      throw MCPContractTestError.connectFailed(errno)
    }
    return fd
  }

  private func sendAll(_ payload: Data, on fd: Int32) throws {
    try payload.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else {
        return
      }
      var bytesSent = 0
      while bytesSent < bytes.count {
        let sent = Darwin.send(
          fd,
          baseAddress.advanced(by: bytesSent),
          bytes.count - bytesSent,
          0
        )
        if sent > 0 {
          bytesSent += sent
          continue
        }
        if sent == 0 {
          throw MCPContractTestError.sendFailed(EPIPE)
        }
        if errno == EINTR {
          continue
        }
        throw MCPContractTestError.sendFailed(errno)
      }
    }
  }

  private func readLine(from fd: Int32) throws -> Data {
    var lineBuffer = NDJSONLineBuffer()
    var scratch = [UInt8](repeating: 0, count: 4 * 1024)
    while true {
      let received = scratch.withUnsafeMutableBufferPointer { buffer in
        Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
      }
      if received > 0 {
        let chunk = Data(scratch.prefix(received))
        let lines: [Data]
        do {
          lines = try lineBuffer.append(
            chunk,
            maxBufferedBytes: RegistryWireCodec.maximumFrameBytes
          )
        } catch {
          throw MCPContractTestError.recvFailed(EMSGSIZE)
        }
        if let line = lines.first {
          return line
        }
        continue
      }
      if received == 0 {
        if let pending = lineBuffer.drainPendingBytes() {
          return pending
        }
        throw MCPContractTestError.recvFailed(ECONNRESET)
      }
      if errno == EINTR {
        continue
      }
      throw MCPContractTestError.recvFailed(errno)
    }
  }
}
