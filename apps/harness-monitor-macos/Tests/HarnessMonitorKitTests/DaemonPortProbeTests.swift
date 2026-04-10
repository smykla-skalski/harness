import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon port probe")
struct DaemonPortProbeTests {
  @Test("Returns true for a bound loopback listener")
  func probeDetectsActiveListener() async throws {
    let listener = try LoopbackListener()
    defer { listener.close() }

    #expect(
      DaemonPortProbe.isListening(
        host: "127.0.0.1",
        port: listener.port,
        timeout: .milliseconds(500)
      )
    )
  }

  @Test("Returns false when the port is closed")
  func probeReturnsFalseForClosedPort() async throws {
    let listener = try LoopbackListener()
    let port = listener.port
    listener.close()

    #expect(
      !DaemonPortProbe.isListening(
        host: "127.0.0.1",
        port: port,
        timeout: .milliseconds(250)
      )
    )
  }

  @Test("Returns false when host is malformed")
  func probeReturnsFalseForMalformedHost() async {
    #expect(
      !DaemonPortProbe.isListening(
        host: "not-an-ip",
        port: 12345,
        timeout: .milliseconds(100)
      )
    )
  }
}

private final class LoopbackListener {
  let descriptor: Int32
  let port: UInt16

  init() throws {
    let fileDescriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
      throw LoopbackListenerError.socketFailed(errno: errno)
    }

    var reuse: Int32 = 1
    _ = setsockopt(
      fileDescriptor,
      SOL_SOCKET,
      SO_REUSEADDR,
      &reuse,
      socklen_t(MemoryLayout<Int32>.size)
    )

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
      Darwin.close(fileDescriptor)
      throw LoopbackListenerError.addressParseFailed
    }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        Darwin.bind(
          fileDescriptor,
          generic,
          socklen_t(MemoryLayout<sockaddr_in>.size)
        )
      }
    }
    guard bindResult == 0 else {
      let bindErrno = errno
      Darwin.close(fileDescriptor)
      throw LoopbackListenerError.bindFailed(errno: bindErrno)
    }
    guard Darwin.listen(fileDescriptor, 1) == 0 else {
      let listenErrno = errno
      Darwin.close(fileDescriptor)
      throw LoopbackListenerError.listenFailed(errno: listenErrno)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
        getsockname(fileDescriptor, generic, &length)
      }
    }
    guard nameResult == 0 else {
      let nameErrno = errno
      Darwin.close(fileDescriptor)
      throw LoopbackListenerError.getsocknameFailed(errno: nameErrno)
    }

    self.descriptor = fileDescriptor
    self.port = UInt16(bigEndian: boundAddress.sin_port)
  }

  func close() {
    Darwin.close(descriptor)
  }
}

private enum LoopbackListenerError: Error {
  case socketFailed(errno: Int32)
  case addressParseFailed
  case bindFailed(errno: Int32)
  case listenFailed(errno: Int32)
  case getsocknameFailed(errno: Int32)
}
