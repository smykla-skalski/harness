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
