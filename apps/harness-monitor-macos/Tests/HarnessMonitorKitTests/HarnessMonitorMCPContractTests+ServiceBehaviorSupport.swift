import Darwin
import Foundation
import HarnessMonitorRegistry
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorMCPContractTests {
  func isolatedDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "io.harnessmonitor.tests.mcp.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.register(defaults: HarnessMonitorMCPPreferencesDefaults.registrationDefaults())
    return (defaults, suiteName)
  }

  func waitForSocket(at path: String, timeout: TimeInterval) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while FileManager.default.fileExists(atPath: path) == false {
      if Date() > deadline {
        throw MCPContractTestError.socketNeverAppeared(path)
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
  }

  func waitForSocketResponse(
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

  func sendLine(_ line: String, toSocketAt path: String) throws -> String {
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

  func connectSocket(to path: String) throws -> Int32 {
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

  func sendAll(_ payload: Data, on fd: Int32) throws {
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

  func readLine(from fd: Int32) throws -> Data {
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

@MainActor
final class MCPContractSemanticPressProbe {
  private(set) var pressCount = 0

  func recordPress() {
    pressCount += 1
  }
}
