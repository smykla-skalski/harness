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
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)
      let response = try sendLine("{\"id\":1,\"op\":\"ping\"}", toSocketAt: socketPath)
      #expect(response.contains("\"ok\":true"))
      #expect(response.contains("\"appVersion\":\"test\""))
      #expect(response.contains("\"client-snapshots\""))
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
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
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

  @Test("stop removes the unix socket path")
  func stopRemovesSocketPath() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      try await listener.start(at: socketPath)
      try await waitForSocket(at: socketPath, timeout: 2)

      await listener.stop()

      #expect(FileManager.default.fileExists(atPath: socketPath) == false)
    }
  }

  @Test("syncClientSnapshot round-trips remote client elements")
  func syncClientSnapshotRoundTrip() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      let socketClient = RegistrySocketClient()
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)

      _ = try await socketClient.syncClientSnapshot(
        RegistryClientSnapshot(
          clientID: UUID(),
          generation: 1,
          appVersion: "test-client",
          bundleIdentifier: "io.test.client",
          snapshot: RegistrySnapshot(
            elements: [
              RegistryElement(
                identifier: "client.refresh",
                kind: .button,
                frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
                windowID: 42
              )
            ],
            windows: []
          )
        ),
        toSocketAt: socketPath
      )

      let response = try sendLine("{\"id\":5,\"op\":\"listElements\"}", toSocketAt: socketPath)
      #expect(response.contains("\"identifier\":\"client.refresh\""))
      #expect(response.contains("\"ok\":true"))
    }
  }

  @Test("round-trips oversized snapshot payloads without truncating the stream")
  func oversizedSnapshotRoundTrip() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      let socketClient = RegistrySocketClient(timeout: 2)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)

      let oversizedLabel = String(repeating: "x", count: 96 * 1024)
      let ack = try await socketClient.syncClientSnapshot(
        RegistryClientSnapshot(
          clientID: UUID(),
          generation: 1,
          appVersion: "test-client",
          bundleIdentifier: "io.test.client",
          snapshot: RegistrySnapshot(
            elements: [
              RegistryElement(
                identifier: "client.huge",
                label: oversizedLabel,
                kind: .row,
                frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
                windowID: 42
              )
            ],
            windows: []
          )
        ),
        toSocketAt: socketPath
      )

      #expect(ack.applied == true)
      let response = try sendLine("{\"id\":5,\"op\":\"listElements\"}", toSocketAt: socketPath)
      #expect(response.contains("\"identifier\":\"client.huge\""))
      #expect(response.contains(String(oversizedLabel.prefix(256))))
    }
  }

  @Test("replacementNotice callbacks run after the ack flushes")
  func replacementNoticeCallbacksRunAfterAckFlushes() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      let delivery = ReplacementNoticeDelivery()
      let notice = RegistryReplacementNotice(
        socketPath: socketPath,
        protocolVersion: 1,
        appVersion: "1.2.4",
        bundleIdentifier: "io.test.replacement",
        message: "replacement incoming"
      )
      let dispatcher = RegistryRequestDispatcher(
        registry: registry,
        pingInfo: {
          PingResult(
            protocolVersion: 1,
            appVersion: "test",
            bundleIdentifier: "io.test",
            capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
          )
        },
        replacementHandler: { _ in
          RegistryRequestDispatcher.ReplacementDisposition(
            ack: RegistryAckResult(applied: true, message: "yielding after the response flushes"),
            onDelivered: { await delivery.record(notice) },
            closeConnectionAfterDelivery: true
          )
        }
      )
      let listener = RegistryListener(dispatcher: dispatcher)
      let socketClient = RegistrySocketClient(timeout: 2)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)

      let ack = try await socketClient.sendReplacementNotice(notice, toSocketAt: socketPath)
      #expect(ack.applied == true)
      try await waitForReplacementNotice(delivery, expected: notice, timeout: 2)
    }
  }

  @Test("a slow reader does not stall unrelated clients")
  func slowReaderDoesNotStallUnrelatedClients() async throws {
    try await withTempSocket { socketPath in
      let registry = AccessibilityRegistry()
      await registry.registerElement(
        RegistryElement(
          identifier: "client.slow-reader",
          label: String(repeating: "x", count: 512 * 1024),
          kind: .row,
          frame: RegistryRect(x: 10, y: 20, width: 24, height: 24),
          windowID: 42
        )
      )
      let dispatcher = RegistryRequestDispatcher(registry: registry) {
        PingResult(
          protocolVersion: 1,
          appVersion: "test",
          bundleIdentifier: "io.test",
          capabilities: [.clientSnapshots, .clientSnapshotLeases, .replacementNotice]
        )
      }
      let listener = RegistryListener(dispatcher: dispatcher)
      try await listener.start(at: socketPath)
      defer { Task { await listener.stop() } }
      try await waitForSocket(at: socketPath, timeout: 2)

      let slowReaderFD = try connectSocket(to: socketPath)
      defer { Darwin.close(slowReaderFD) }
      var receiveBufferSize: Int32 = 1_024
      _ = Darwin.setsockopt(
        slowReaderFD,
        SOL_SOCKET,
        SO_RCVBUF,
        &receiveBufferSize,
        socklen_t(MemoryLayout<Int32>.size)
      )
      try sendAll(Data("{\"id\":21,\"op\":\"listElements\"}\n".utf8), on: slowReaderFD)
      try await Task.sleep(nanoseconds: 50_000_000)

      let start = Date()
      let response = try sendLine("{\"id\":1,\"op\":\"ping\"}", toSocketAt: socketPath)
      let elapsed = Date().timeIntervalSince(start)

      #expect(response.contains("\"ok\":true"))
      #expect(elapsed < 0.5)
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
    let fd = try connectSocket(to: path)
    defer { Darwin.close(fd) }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let payload = Data((line + "\n").utf8)
    try sendAll(payload, on: fd)
    let responseData = try readLine(from: fd)
    return String(data: responseData, encoding: .utf8) ?? ""
  }

  private func connectSocket(to path: String) throws -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw IntegrationTestError.clientSocketFailed(errno) }

    var noSigPipe: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
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
      throw IntegrationTestError.connectFailed(errno)
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
          throw IntegrationTestError.sendFailed(EPIPE)
        }
        if errno == EINTR {
          continue
        }
        throw IntegrationTestError.sendFailed(errno)
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
        do {
          let lines = try lineBuffer.append(chunk, maxBufferedBytes: RegistryWireCodec.maximumFrameBytes)
          if let line = lines.first {
            return line
          }
        } catch let error as RegistryWireCodecError {
          switch error {
          case .frameTooLarge(let maxBytes):
            throw IntegrationTestError.frameTooLarge(maxBytes)
          }
        }
        continue
      }
      if received == 0 {
        if let pending = lineBuffer.drainPendingBytes() {
          return pending
        }
        throw IntegrationTestError.recvFailed(ECONNRESET)
      }
      if errno == EINTR {
        continue
      }
      throw IntegrationTestError.recvFailed(errno)
    }
  }

  private func waitForReplacementNotice(
    _ delivery: ReplacementNoticeDelivery,
    expected: RegistryReplacementNotice,
    timeout: TimeInterval
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if await delivery.matches(expected) {
        return
      }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(await delivery.matches(expected))
  }
}

enum IntegrationTestError: Error, CustomStringConvertible {
  case socketNeverAppeared(String)
  case clientSocketFailed(Int32)
  case connectFailed(Int32)
  case sendFailed(Int32)
  case recvFailed(Int32)
  case frameTooLarge(Int)

  var description: String {
    switch self {
    case .socketNeverAppeared(let path): return "socket never appeared at \(path)"
    case .clientSocketFailed(let code): return "socket() failed: \(String(cString: strerror(code)))"
    case .connectFailed(let code): return "connect() failed: \(String(cString: strerror(code)))"
    case .sendFailed(let code): return "send() failed: \(String(cString: strerror(code)))"
    case .recvFailed(let code): return "recv() failed: \(String(cString: strerror(code)))"
    case .frameTooLarge(let maxBytes): return "frame exceeded \(maxBytes) bytes"
    }
  }
}

actor ReplacementNoticeDelivery {
  private var deliveredNotice: RegistryReplacementNotice?

  func record(_ notice: RegistryReplacementNotice) {
    deliveredNotice = notice
  }

  func matches(_ notice: RegistryReplacementNotice) -> Bool {
    deliveredNotice == notice
  }
}
