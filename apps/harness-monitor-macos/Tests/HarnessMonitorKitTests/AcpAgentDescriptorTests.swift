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
    XCTAssertFalse(descriptor.excludedFromInitialDefault)
  }

  func testDescriptorDecodesInitialDefaultExclusionWhenPresent() throws {
    let json = Data(
      """
      {
        "id": "claude",
        "display_name": "Claude Code",
        "capabilities": ["fs.read", "terminal.spawn"],
        "launch_command": "claude-agent-acp",
        "launch_args": [],
        "env_passthrough": ["ANTHROPIC_API_KEY"],
        "doctor_probe": {
          "command": "claude-agent-acp",
          "args": ["--cli", "auth", "status"]
        },
        "excluded_from_initial_default": true
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let descriptor = try decoder.decode(AcpAgentDescriptor.self, from: json)

    XCTAssertTrue(descriptor.excludedFromInitialDefault)
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

  func testStartRequestEncodesOrchestrationFieldsAndRecordingPermissionToggle() throws {
    let request = AcpAgentStartRequest(
      agent: "copilot",
      role: .reviewer,
      fallbackRole: .observer,
      capabilities: ["fs.read", "terminal.spawn"],
      name: "Copilot Reviewer",
      prompt: "Run the task",
      projectDir: "/tmp/harness",
      persona: "reviewer",
      model: "gpt-5.4",
      effort: "high",
      allowCustomModel: true,
      recordPermissions: true
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["descriptor_id"] as? String, "copilot")
    XCTAssertNil(json?["agent"])
    XCTAssertEqual(json?["role"] as? String, "reviewer")
    XCTAssertEqual(json?["fallback_role"] as? String, "observer")
    XCTAssertEqual(json?["capabilities"] as? [String], ["fs.read", "terminal.spawn"])
    XCTAssertEqual(json?["name"] as? String, "Copilot Reviewer")
    XCTAssertEqual(json?["persona"] as? String, "reviewer")
    XCTAssertEqual(json?["model"] as? String, "gpt-5.4")
    XCTAssertEqual(json?["effort"] as? String, "high")
    XCTAssertEqual(json?["allow_custom_model"] as? Bool, true)
    XCTAssertEqual(json?["record_permissions"] as? Bool, true)
  }

  func testStartRequestDecodesCanonicalDescriptorID() throws {
    let json = Data(
      """
      {
        "descriptor_id": "copilot",
        "role": "reviewer",
        "fallback_role": "observer",
        "model": "gpt-5.4",
        "effort": "high",
        "allow_custom_model": true,
        "record_permissions": true
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let request = try decoder.decode(AcpAgentStartRequest.self, from: json)

    XCTAssertEqual(request.agent, "copilot")
    XCTAssertEqual(request.role, .reviewer)
    XCTAssertEqual(request.fallbackRole, .observer)
    XCTAssertEqual(request.model, "gpt-5.4")
    XCTAssertEqual(request.effort, "high")
    XCTAssertTrue(request.allowCustomModel)
    XCTAssertTrue(request.recordPermissions)
  }

  func testStartRequestRejectsLegacyAgentAliases() {
    let json = Data(
      """
      {
        "agent": "copilot",
        "agent_id": "copilot"
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(AcpAgentStartRequest.self, from: json))
  }

  func testStartRequestRejectsMissingDescriptorID() {
    let json = Data(
      """
      {
        "role": "reviewer"
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(AcpAgentStartRequest.self, from: json))
  }

  func testInspectSnapshotDecodesPermissionRecordingFields() throws {
    let json = Data(
      """
      {
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "session-1",
        "session_agent_id": "copilot",
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
    XCTAssertEqual(snapshot.managedAgentID, "acp-1")
    XCTAssertEqual(snapshot.sessionAgentID, "copilot")
  }

  func testInspectSnapshotDefaultsMissingPermissionFields() throws {
    let json = Data(
      """
      {
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "session-1",
        "session_agent_id": "copilot",
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

  func testInspectSnapshotRejectsMissingManagedAgentFamily() {
    let json = Data(
      """
      {
        "managed_agent_id": "acp-1",
        "session_id": "session-1",
        "session_agent_id": "copilot",
        "display_name": "GitHub Copilot",
        "pid": 123,
        "pgid": 123,
        "uptime_ms": 5000,
        "last_update_at": "2026-04-28T00:00:00Z",
        "watchdog_state": "healthy",
        "pending_permissions": 0,
        "terminal_count": 0,
        "prompt_deadline_remaining_ms": 45000
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(AcpAgentInspectSnapshot.self, from: json))
  }

  func testDescriptorRelatedModelsExposeTypedIdentities() {
    let descriptor = AcpAgentDescriptor(
      id: "copilot",
      displayName: "GitHub Copilot",
      capabilities: ["fs.read"],
      launchCommand: "copilot",
      launchArgs: ["--acp"],
      envPassthrough: ["GH_TOKEN"],
      doctorProbe: AcpDoctorProbe(command: "copilot", args: ["--version"])
    )
    let probe = AcpRuntimeProbe(
      agentId: "copilot",
      displayName: "GitHub Copilot",
      binaryPresent: true,
      authState: .ready
    )
    let request = AcpAgentStartRequest(agent: "copilot", role: .reviewer)

    XCTAssertEqual(descriptor.descriptorIdentity, AcpDescriptorID(rawValue: "copilot"))
    XCTAssertEqual(probe.descriptorIdentity, descriptor.descriptorIdentity)
    XCTAssertEqual(request.descriptorIdentity, descriptor.descriptorIdentity)
  }

  func testAcpSnapshotDecodesCanonicalIdentityFields() throws {
    let json = Data(
      """
      {
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "session-1",
        "session_agent_id": "agent-1",
        "display_name": "GitHub Copilot",
        "status": "active",
        "pid": 123,
        "pgid": 123,
        "project_dir": "/tmp/harness",
        "pending_permissions": 0,
        "permission_queue_depth": 0,
        "pending_permission_batches": [],
        "terminal_count": 0,
        "created_at": "2026-04-28T00:00:00Z",
        "updated_at": "2026-04-28T00:00:01Z"
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let snapshot = try decoder.decode(AcpAgentSnapshot.self, from: json)

    XCTAssertEqual(snapshot.managedAgentID, "acp-1")
    XCTAssertEqual(snapshot.sessionAgentID, "agent-1")
  }

  func testAcpSnapshotRejectsMissingManagedAgentFamily() {
    let json = Data(
      """
      {
        "managed_agent_id": "acp-1",
        "session_id": "session-1",
        "session_agent_id": "agent-1",
        "display_name": "GitHub Copilot",
        "status": "active",
        "pid": 123,
        "pgid": 123,
        "project_dir": "/tmp/harness",
        "pending_permissions": 0,
        "permission_queue_depth": 0,
        "pending_permission_batches": [],
        "terminal_count": 0,
        "created_at": "2026-04-28T00:00:00Z",
        "updated_at": "2026-04-28T00:00:01Z"
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase

    XCTAssertThrowsError(try decoder.decode(AcpAgentSnapshot.self, from: json))
  }
}
