import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the host-bridge reconfigure response. Generated from
/// bridge/types.rs; capabilities reuse the daemon-state HostBridgeCapabilityManifest map and
/// pid/uptime narrow UInt -> Int.
@Suite("Bridge status wire decoding")
struct BridgeStatusWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("bridge status report maps the scalars and capability map")
  func bridgeStatusMapping() throws {
    let payload = #"""
      {
        "running": true, "socket_path": "/tmp/bridge.sock", "pid": 4321,
        "started_at": "2026-06-18T10:00:00Z", "uptime_seconds": 120,
        "capabilities": {
          "codex": {"enabled": true, "healthy": true, "transport": "websocket",
            "endpoint": "ws://127.0.0.1:9000", "metadata": {}}
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(BridgeStatusReportWire.self, from: data)
    let report = BridgeStatusReport(wire: wire)

    #expect(report.running == true)
    #expect(report.socketPath == "/tmp/bridge.sock")
    #expect(report.pid == 4321)
    #expect(report.uptimeSeconds == 120)
    #expect(report.capabilities["codex"]?.transport == "websocket")
    #expect(report.capabilities["codex"]?.endpoint == "ws://127.0.0.1:9000")
  }
}
