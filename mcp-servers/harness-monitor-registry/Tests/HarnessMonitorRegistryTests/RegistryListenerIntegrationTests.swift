import Darwin
import Foundation
import Testing
@testable import HarnessMonitorRegistry

@Suite("RegistryListener integration")
struct RegistryListenerIntegrationTests {
  @Test("round-trips a ping over a unix socket")
  func pingRoundTrip() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(protocolVersion: 1, appVersion: "test", bundleIdentifier: "io.test")
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)
      let response = try sendLine("{\"id\":1,\"op\":\"ping\"}", toSocketAt: socketPath)
      #expect(response.contains("\"ok\":true"))
      #expect(response.contains("\"appVersion\":\"test\""))
    }
  }

  @Test("listElements returns registered elements")
  func listElementsRoundTrip() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      await registry.registerElement(
        RegistryElement(
          identifier: "toolbar.refresh",
          label: "Refresh",
          kind: .button,
          frame: RegistryRect(x: 100, y: 50, width: 32, height: 32),
          windowID: 42
        )
      )
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(protocolVersion: 1, appVersion: "test", bundleIdentifier: "io.test")
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)
      let response = try sendLine("{\"id\":5,\"op\":\"listElements\"}", toSocketAt: socketPath)
      #expect(response.contains("\"identifier\":\"toolbar.refresh\""))
      #expect(response.contains("\"ok\":true"))
    }
  }

  // MARK: - Helpers

  private func withTempSocket<T>(_ body: (String) async throws -> T) async throws -> T {
    let dir = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("hm-reg-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir.appendingPathComponent("s").path)
  }

  private func waitForSocket(at path: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while FileManager.default.fileExists(atPath: path) == false {
      if Date() > deadline {
        throw IntegrationTestError.socketNeverAppeared(path)
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  private func sendLine(_ line: String, toSocketAt path: String) throws -> String {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IntegrationTestError.clientSocketFailed(errno) }
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
    if connectResult != 0 { throw IntegrationTestError.connectFailed(errno) }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((line + "\n").utf8)
    let sent = payload.withUnsafeBytes { buffer in
      Darwin.send(fd, buffer.baseAddress, buffer.count, 0)
    }
    if sent < 0 { throw IntegrationTestError.sendFailed(errno) }

    var responseData = Data()
    var scratch = [UInt8](repeating: 0, count: 64 * 1024)
    let received = scratch.withUnsafeMutableBufferPointer { buffer in
      Darwin.recv(fd, buffer.baseAddress, buffer.count, 0)
    }
    if received < 0 { throw IntegrationTestError.recvFailed(errno) }
    responseData.append(scratch, count: received)
    return String(data: responseData, encoding: .utf8) ?? ""
  }
}

enum IntegrationTestError: Error, CustomStringConvertible {
  case socketNeverAppeared(String)
  case clientSocketFailed(Int32)
  case connectFailed(Int32)
  case sendFailed(Int32)
  case recvFailed(Int32)

  var description: String {
    switch self {
    case .socketNeverAppeared(let path): return "socket never appeared at \(path)"
    case .clientSocketFailed(let code): return "socket() failed: \(String(cString: strerror(code)))"
    case .connectFailed(let code): return "connect() failed: \(String(cString: strerror(code)))"
    case .sendFailed(let code): return "send() failed: \(String(cString: strerror(code)))"
    case .recvFailed(let code): return "recv() failed: \(String(cString: strerror(code)))"
    }
  }
}
