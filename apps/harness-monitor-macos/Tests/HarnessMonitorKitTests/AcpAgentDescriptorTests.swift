import HarnessMonitorKit
import XCTest

final class AcpAgentDescriptorTests: XCTestCase {
  func testDescriptorRoundTripsFromSnakeCaseConfigPayload() throws {
    let json = Data(
      """
      {
        "id": "copilot",
        "display_name": "GitHub Copilot",
        "capabilities": ["fs.read", "fs.write", "terminal.spawn"],
        "launch_command": "copilot",
        "launch_args": ["--acp", "--stdio"],
        "env_passthrough": ["GH_TOKEN"],
        "install_hint": "Install GitHub Copilot CLI.",
        "doctor_probe": {
          "command": "copilot",
          "args": ["--version"]
        }
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let descriptor = try decoder.decode(AcpAgentDescriptor.self, from: json)

    XCTAssertEqual(descriptor.id, "copilot")
    XCTAssertEqual(descriptor.displayName, "GitHub Copilot")
    XCTAssertEqual(descriptor.launchArgs, ["--acp", "--stdio"])
    XCTAssertEqual(descriptor.doctorProbe.command, "copilot")
  }

  func testConfigurationDefaultsAcpFields() throws {
    let json = Data(
      """
      {
        "personas": [],
        "runtime_models": []
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let configuration = try decoder.decode(MonitorConfiguration.self, from: json)

    XCTAssertTrue(configuration.acpAgents.isEmpty)
    XCTAssertNil(configuration.runtimeProbe)
  }

  func testStartRequestEncodesRecordingPermissionToggle() throws {
    let request = AcpAgentStartRequest(
      agent: "copilot",
      prompt: "Run the task",
      projectDir: "/tmp/harness",
      recordPermissions: true
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["agent"] as? String, "copilot")
    XCTAssertEqual(json?["record_permissions"] as? Bool, true)
  }

  func testInspectSnapshotDecodesPermissionRecordingFields() throws {
    let json = Data(
      """
      {
        "acp_id": "acp-1",
        "session_id": "session-1",
        "agent_id": "copilot",
        "display_name": "GitHub Copilot",
        "pid": 123,
        "pgid": 123,
        "uptime_ms": 5000,
        "last_update_at": "2026-04-28T00:00:00Z",
        "last_client_call_at": null,
        "watchdog_state": "healthy",
        "permission_mode": "recording",
        "permission_log_path": "/tmp/permission-log.ndjson",
        "pending_permissions": 2,
        "permission_queue_depth": 1,
        "terminal_count": 0,
        "prompt_deadline_remaining_ms": 45000
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let snapshot = try decoder.decode(AcpAgentInspectSnapshot.self, from: json)

    XCTAssertEqual(snapshot.permissionMode, "recording")
    XCTAssertEqual(snapshot.permissionLogPath, "/tmp/permission-log.ndjson")
    XCTAssertEqual(snapshot.permissionQueueDepth, 1)
  }

  func testInspectSnapshotDefaultsMissingPermissionFields() throws {
    let json = Data(
      """
      {
        "acp_id": "acp-1",
        "session_id": "session-1",
        "agent_id": "copilot",
        "display_name": "GitHub Copilot",
        "pid": 123,
        "pgid": 123,
        "uptime_ms": 5000,
        "last_update_at": "2026-04-28T00:00:00Z",
        "last_client_call_at": null,
        "watchdog_state": "healthy",
        "pending_permissions": 0,
        "terminal_count": 0,
        "prompt_deadline_remaining_ms": 45000
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let snapshot = try decoder.decode(AcpAgentInspectSnapshot.self, from: json)

    XCTAssertEqual(snapshot.permissionMode, "")
    XCTAssertNil(snapshot.permissionLogPath)
    XCTAssertEqual(snapshot.permissionQueueDepth, 0)
  }
}
