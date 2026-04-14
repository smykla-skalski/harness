import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon manifest decoding")
struct DaemonManifestDecodingTests {
  @Test("Legacy manifest without sandbox fields decodes with defaults")
  func legacyManifestDecodesWithDefaults() throws {
    let json = """
      {
        "version": "14.5.0",
        "pid": 4242,
        "endpoint": "http://127.0.0.1:9999",
        "started_at": "2026-03-28T14:00:00Z",
        "token_path": "/tmp/token"
      }
      """

    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let manifest = try decoder.decode(DaemonManifest.self, from: data)

    #expect(manifest.version == "14.5.0")
    #expect(manifest.pid == 4_242)
    #expect(manifest.endpoint == "http://127.0.0.1:9999")
    #expect(manifest.startedAt == "2026-03-28T14:00:00Z")
    #expect(manifest.tokenPath == "/tmp/token")
    #expect(manifest.sandboxed == false)
    #expect(manifest.hostBridge == HostBridgeManifest())
    #expect(manifest.revision == 0)
    #expect(manifest.updatedAt == nil)
  }

  @Test("Current manifest decodes revision and updated_at")
  func currentManifestDecodesRevisionAndUpdatedAt() throws {
    let json = """
      {
        "version": "19.5.2",
        "pid": 1,
        "endpoint": "http://127.0.0.1:0",
        "started_at": "2026-04-11T15:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": true,
        "host_bridge": {
          "running": true,
          "socket_path": "/tmp/bridge.sock",
          "capabilities": {}
        },
        "revision": 7,
        "updated_at": "2026-04-11T15:30:00Z",
        "binary_stamp": {
          "helper_path": "/Applications/Harness Monitor.app/Contents/Helpers/harness",
          "device_identifier": 41,
          "inode": 84,
          "file_size": 16384,
          "modification_time_interval_since_1970": 1713000000
        }
      }
      """

    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let manifest = try decoder.decode(DaemonManifest.self, from: data)

    #expect(manifest.revision == 7)
    #expect(manifest.updatedAt == "2026-04-11T15:30:00Z")
    #expect(
      manifest.binaryStamp
        == DaemonBinaryStamp(
          helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
          deviceIdentifier: 41,
          inode: 84,
          fileSize: 16_384,
          modificationTimeIntervalSince1970: 1_713_000_000
        )
    )
  }

  @Test("Revision round-trips through encode + decode")
  func revisionRoundTripsThroughEncodeDecode() throws {
    let original = DaemonManifest(
      version: "19.5.2",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T15:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(running: true),
      revision: 42,
      updatedAt: "2026-04-11T15:30:00Z",
      binaryStamp: DaemonBinaryStamp(
        helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness",
        deviceIdentifier: 41,
        inode: 84,
        fileSize: 16_384,
        modificationTimeIntervalSince1970: 1_713_000_000
      )
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(DaemonManifest.self, from: data)

    #expect(decoded == original)
    #expect(decoded.revision == 42)
    #expect(decoded.updatedAt == "2026-04-11T15:30:00Z")
    #expect(decoded.binaryStamp == original.binaryStamp)
  }

  @Test("Legacy sandbox manifest decodes bridge fallback fields")
  func sandboxManifestDecodesAllFields() throws {
    let json = """
      {
        "version": "14.5.0",
        "pid": 4242,
        "endpoint": "http://127.0.0.1:9999",
        "started_at": "2026-03-28T14:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": true,
        "codex_transport": "websocket",
        "codex_endpoint": "ws://127.0.0.1:9999/v1/codex"
      }
      """

    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let manifest = try decoder.decode(DaemonManifest.self, from: data)

    #expect(manifest.sandboxed == true)
    #expect(manifest.hostBridge.running == true)
    #expect(manifest.hostBridge.capabilities["codex"]?.transport == "websocket")
    #expect(manifest.hostBridge.capabilities["codex"]?.endpoint == "ws://127.0.0.1:9999/v1/codex")
  }

  @Test("Unified host bridge manifest decodes all fields")
  func unifiedBridgeManifestDecodesAllFields() throws {
    let json = """
      {
        "version": "19.0.0",
        "pid": 4242,
        "endpoint": "http://127.0.0.1:9999",
        "started_at": "2026-04-11T14:00:00Z",
        "token_path": "/tmp/token",
        "sandboxed": true,
        "host_bridge": {
          "running": true,
          "socket_path": "/tmp/bridge.sock",
          "capabilities": {
            "codex": {
              "enabled": true,
              "healthy": true,
              "transport": "websocket",
              "endpoint": "ws://127.0.0.1:4500",
              "metadata": {
                "port": "4500"
              }
            },
            "agent-tui": {
              "enabled": true,
              "healthy": true,
              "transport": "unix",
              "endpoint": "/tmp/bridge.sock",
              "metadata": {
                "active_sessions": "1"
              }
            }
          }
        }
      }
      """

    let data = Data(json.utf8)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    let manifest = try decoder.decode(DaemonManifest.self, from: data)

    #expect(manifest.hostBridge.running == true)
    #expect(manifest.hostBridge.socketPath == "/tmp/bridge.sock")
    #expect(manifest.hostBridge.capabilities["codex"]?.metadata["port"] == "4500")
    #expect(manifest.hostBridge.capabilities["agent-tui"]?.metadata["active_sessions"] == "1")
  }

  @Test("Host bridge fields round-trip through encode + decode")
  func sandboxFieldsRoundTrip() throws {
    let original = DaemonManifest(
      version: "14.5.0",
      pid: 4_242,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-03-28T14:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:9999/v1/codex",
            metadata: ["port": "9999"]
          )
        ]
      )
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(original)

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let decoded = try decoder.decode(DaemonManifest.self, from: data)

    #expect(decoded == original)
  }
}
