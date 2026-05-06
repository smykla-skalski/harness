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
      recordPermissions: true
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(request)
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

    XCTAssertEqual(json?["descriptor_id"] as? String, "copilot")
    XCTAssertEqual(json?["agent"] as? String, "copilot")
    XCTAssertEqual(json?["role"] as? String, "reviewer")
    XCTAssertEqual(json?["fallback_role"] as? String, "observer")
    XCTAssertEqual(json?["capabilities"] as? [String], ["fs.read", "terminal.spawn"])
    XCTAssertEqual(json?["name"] as? String, "Copilot Reviewer")
    XCTAssertEqual(json?["persona"] as? String, "reviewer")
    XCTAssertEqual(json?["record_permissions"] as? Bool, true)
  }

  func testStartRequestDecodesDescriptorIDAlias() throws {
    let json = Data(
      """
      {
        "descriptor_id": "copilot",
        "role": "reviewer",
        "fallback_role": "observer",
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
    XCTAssertTrue(request.recordPermissions)
  }

  func testInspectSnapshotDecodesPermissionRecordingFields() throws {
    let json = Data(
      """
      {
        "acp_id": "legacy-acp",
        "managed_agent_id": "acp-1",
        "session_id": "session-1",
        "agent_id": "legacy-agent",
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

  func testAcpSnapshotPrefersExplicitIdentityFields() throws {
    let json = Data(
      """
      {
        "acp_id": "legacy-acp",
        "managed_agent_id": "acp-1",
        "session_id": "session-1",
        "agent_id": "legacy-agent",
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

  func testAcpEventBatchPayloadAcceptsManagedAgentAlias() throws {
    let json = Data(
      """
      {
        "acp_id": "legacy-acp",
        "managed_agent_id": "acp-1",
        "managed_agent_family": "acp",
        "session_id": "session-1",
        "raw_count": 1,
        "events": [
          {
            "timestamp": "2026-04-28T00:00:00Z",
            "sequence": 1,
            "kind": { "type": "tool_invocation" },
            "agent": "copilot",
            "session_id": "session-1"
          }
        ]
      }
      """.utf8
    )

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let payload = try decoder.decode(AcpEventBatchPayload.self, from: json)

    XCTAssertEqual(payload.acpId, "acp-1")

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let encoded = try encoder.encode(payload)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertEqual(object["acp_id"] as? String, "acp-1")
    XCTAssertEqual(object["managed_agent_id"] as? String, "acp-1")
    XCTAssertEqual(object["managed_agent_family"] as? String, "acp")
  }


  func testManagedAgentClientShimsAcceptTypedIdentities() async throws {
    let client = RecordingHarnessClient()
    let sessionID = HarnessSessionID(rawValue: "session-shim")
    let existingTerminal = client.agentTuiFixture(tuiID: "tui-shim", sessionID: sessionID.rawValue)
    let existingCodex = client.codexRunFixture(runID: "codex-shim", sessionID: sessionID.rawValue)
    client.recordAgentTui(existingTerminal)
    client.recordCodexRun(existingCodex)

    let managedAgents = try await client.managedAgents(sessionID: sessionID)
    XCTAssertEqual(
      Set(managedAgents.agents.map(\.managedAgentIdentity)),
      Set([existingTerminal.managedAgentIdentity, existingCodex.managedAgentIdentity])
    )

    let managedAgent = try await client.managedAgent(agentID: existingTerminal.managedAgentIdentity)
    XCTAssertEqual(managedAgent.managedAgentIdentity, existingTerminal.managedAgentIdentity)

    let fetchedTerminal = try await client.agentTui(tuiID: existingTerminal.managedAgentIdentity)
    XCTAssertEqual(fetchedTerminal.managedAgentIdentity, existingTerminal.managedAgentIdentity)

    let fetchedCodex = try await client.codexRun(runID: existingCodex.managedAgentIdentity)
    XCTAssertEqual(fetchedCodex.managedAgentIdentity, existingCodex.managedAgentIdentity)

    let startedTerminal = try await client.startAgentTui(
      sessionID: sessionID,
      request: AgentTuiStartRequest(runtime: AgentTuiRuntime.copilot.rawValue)
    )
    XCTAssertEqual(startedTerminal.sessionIdentity, sessionID)

    let startedCodex = try await client.startCodexRun(
      sessionID: sessionID,
      request: CodexRunRequest(actor: nil, prompt: "Summarize", mode: .report)
    )
    XCTAssertEqual(startedCodex.sessionIdentity, sessionID)

    let startedAcp = try await client.startManagedAcpAgent(
      sessionID: sessionID,
      request: AcpAgentStartRequest(agent: "copilot")
    )
    XCTAssertEqual(startedAcp.acp?.sessionIdentity, Optional(sessionID))
  }

  func testRecordingAcpStartKeepsIdentityClassesDistinct() async throws {
    let client = RecordingHarnessClient()
    let sessionID = HarnessSessionID(rawValue: "session-recording")

    let started = try await client.startManagedAcpAgent(
      sessionID: sessionID,
      request: AcpAgentStartRequest(agent: "copilot")
    )
    let snapshot = try XCTUnwrap(started.acp)

    XCTAssertEqual(snapshot.sessionIdentity, sessionID)
    XCTAssertTrue(snapshot.sessionAgentID.hasPrefix("recording-session-agent-copilot-"))
    XCTAssertTrue(snapshot.managedAgentID.hasPrefix("acp-"))
    XCTAssertNotEqual(snapshot.managedAgentID, snapshot.sessionAgentID)

    let detail = try await client.sessionDetail(id: sessionID.rawValue, scope: nil)
    let registration = try XCTUnwrap(detail.agents.first { $0.agentId == snapshot.sessionAgentID })
    XCTAssertEqual(registration.managedAgentID, snapshot.managedAgentID)
    XCTAssertTrue(registration.runtimeSessionID?.hasPrefix("recording-runtime-session-") == true)
    XCTAssertNotEqual(registration.runtimeSessionID, snapshot.sessionAgentID)

    do {
      _ = try await client.managedAgent(agentID: snapshot.sessionAgentID)
      XCTFail("expected managed-agent lookup by session-agent id to fail")
    } catch {
      XCTAssertTrue(error is HarnessMonitorAPIError)
    }
  }

  func testPreviewClientRejectsUnknownSessionReads() async throws {
    let client = PreviewHarnessClient(
      fixtures: .populated,
      isLaunchAgentInstalled: true
    )

    do {
      _ = try await client.sessionDetail(id: "missing-session", scope: nil)
      XCTFail("expected missing preview session detail to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }

    do {
      _ = try await client.timeline(sessionID: "missing-session")
      XCTFail("expected missing preview timeline to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }

    do {
      _ = try await client.acpTranscript(sessionID: "missing-session")
      XCTFail("expected missing preview ACP transcript to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }
  }

  func testRecordingClientRejectsUnknownSessionReadsAndAcpPermissionResolution() async throws {
    let client = RecordingHarnessClient()

    do {
      _ = try await client.sessionDetail(id: "missing-session", scope: nil)
      XCTFail("expected missing recording session detail to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }

    do {
      _ = try await client.timeline(sessionID: "missing-session")
      XCTFail("expected missing recording timeline to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }

    do {
      _ = try await client.acpTranscript(sessionID: "missing-session")
      XCTFail("expected missing recording ACP transcript to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }

    do {
      _ = try await client.resolveManagedAcpPermission(
        agentID: "missing-agent",
        batchID: "missing-batch",
        decision: .denyAll
      )
      XCTFail("expected unknown ACP permission resolution to throw")
    } catch let error as HarnessMonitorAPIError {
      guard case .server(let code, _) = error else {
        return XCTFail("expected server error, got \(error)")
      }
      XCTAssertEqual(code, 404)
    }
  }

}
