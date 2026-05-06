import HarnessMonitorKit
import XCTest

extension AcpAgentDescriptorTests {
  func testAcpSnapshotDecodesCanonicalIdentityFields() throws {
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
    let snapshot = try decoder.decode(AcpAgentSnapshot.self, from: json)

    XCTAssertEqual(snapshot.managedAgentID, "acp-1")
    XCTAssertEqual(snapshot.sessionAgentID, "agent-1")
  }

  func testAcpEventBatchPayloadUsesCanonicalManagedAgentIdentity() throws {
    let json = Data(
      """
      {
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
    XCTAssertEqual(object["managed_agent_id"] as? String, "acp-1")
    XCTAssertEqual(object["managed_agent_family"] as? String, "acp")
    XCTAssertNil(object["acp_id"])
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
