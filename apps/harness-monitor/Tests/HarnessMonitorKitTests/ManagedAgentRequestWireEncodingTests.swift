import Foundation
import Testing

@testable import HarnessMonitorKit

/// Encode contract for the managed-agent mutation request bodies. The domain request maps to a
/// generated *Wire whose CodingKeys are pinned to the daemon's serde field names, so a plain
/// JSONEncoder (no key strategy) already emits snake_case - it does not depend on
/// convertToSnakeCase guessing the keys from camelCase. The idempotence test proves the shared
/// production encoder (convertToSnakeCase) yields the identical key set on the wire.
@Suite("Managed agent request wire encoding")
struct ManagedAgentRequestWireEncodingTests {
  private func object(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  @Test("terminal start request pins the daemon snake keys")
  func startTerminal() throws {
    let request = AgentTuiStartRequest(
      runtime: "claude",
      role: .worker,
      capabilities: ["fs"],
      projectDir: "/tmp/x",
      taskID: "task-1",
      boardItemID: "board-1",
      workflowExecutionID: "wf-1",
      allowCustomModel: true,
      argv: ["--foo"],
      rows: 40,
      cols: 100
    )
    let json = try object(AgentTuiStartRequestWire(request))
    #expect(json["project_dir"] as? String == "/tmp/x")
    #expect(json["task_id"] as? String == "task-1")
    #expect(json["board_item_id"] as? String == "board-1")
    #expect(json["workflow_execution_id"] as? String == "wf-1")
    #expect(json["allow_custom_model"] as? Bool == true)
    #expect(json["role"] as? String == "worker")
    #expect(json["rows"] as? Int == 40)
    #expect(json["cols"] as? Int == 100)
    // The terminal request carries no fallback role, so the wire omits the key.
    #expect(json["fallback_role"] == nil)
  }

  @Test("codex run request pins snake keys and applies daemon defaults")
  func startCodex() throws {
    let request = CodexRunRequest(
      actor: nil,
      prompt: "go",
      mode: .workspaceWrite,
      fallbackRole: .reviewer,
      resumeThreadId: "thread-7",
      taskID: "task-2",
      allowCustomModel: true
    )
    let json = try object(CodexRunRequestWire(request))
    #expect(json["prompt"] as? String == "go")
    #expect(json["mode"] as? String == "workspace_write")
    #expect(json["fallback_role"] as? String == "reviewer")
    #expect(json["resume_thread_id"] as? String == "thread-7")
    #expect(json["task_id"] as? String == "task-2")
    #expect(json["allow_custom_model"] as? Bool == true)
    // The hand request leaves role and capabilities nil; the wire mirrors the daemon defaults.
    #expect(json["role"] as? String == "worker")
    #expect(json["capabilities"] as? [String] == [])
  }

  @Test("resize, steer and approval requests encode faithfully")
  func simpleRequests() throws {
    let resize = try object(AgentTuiResizeRequestWire(AgentTuiResizeRequest(rows: 50, cols: 80)))
    #expect(resize["rows"] as? Int == 50)
    #expect(resize["cols"] as? Int == 80)

    let steer = try object(CodexSteerRequestWire(CodexSteerRequest(prompt: "stop")))
    #expect(steer["prompt"] as? String == "stop")

    let approval = try object(
      CodexApprovalDecisionRequestWire(CodexApprovalDecisionRequest(decision: .acceptForSession))
    )
    #expect(approval["decision"] as? String == "accept_for_session")
  }

  @Test("convertToSnakeCase is idempotent on the wire's pinned keys")
  func convertSnakeCaseIdempotent() throws {
    let wire = AgentTuiStartRequestWire(
      AgentTuiStartRequest(
        runtime: "claude", projectDir: "/tmp/x", taskID: "t", allowCustomModel: true
      )
    )
    let convertEncoder = JSONEncoder()
    convertEncoder.keyEncodingStrategy = .convertToSnakeCase
    let plain = try JSONEncoder().encode(wire)
    let converted = try convertEncoder.encode(wire)
    let plainKeys = Set(try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any]).keys)
    let convertedKeys = Set(
      try #require(JSONSerialization.jsonObject(with: converted) as? [String: Any]).keys
    )
    #expect(plainKeys == convertedKeys)
  }

  @Test("acp permission decision pins the request_ids key")
  func acpPermissionDecision() throws {
    let approveSome = try object(AcpPermissionDecisionWire(.approveSome(["id-1", "id-2"])))
    #expect(approveSome["decision"] as? String == "approve_some")
    #expect(approveSome["request_ids"] as? [String] == ["id-1", "id-2"])

    let approveAll = try object(AcpPermissionDecisionWire(.approveAll))
    #expect(approveAll["decision"] as? String == "approve_all")
    #expect(approveAll["request_ids"] == nil)
  }

  @Test("acp start request pins descriptor_id and snake keys")
  func acpStartRequest() throws {
    let request = AcpAgentStartRequest(
      agent: "claude-acp",
      projectDir: "/tmp/acp",
      taskID: "task-9",
      allowCustomModel: true,
      recordPermissions: true
    )
    let json = try object(AcpAgentStartRequestWire(request))
    #expect(json["descriptor_id"] as? String == "claude-acp")
    #expect(json["project_dir"] as? String == "/tmp/acp")
    #expect(json["task_id"] as? String == "task-9")
    #expect(json["allow_custom_model"] as? Bool == true)
    #expect(json["record_permissions"] as? Bool == true)
    #expect(json["role"] as? String == "worker")
  }

  @Test("agent-tui input request wraps the input event faithfully")
  func agentTuiInput() throws {
    let json = try object(AgentTuiInputRequestWire(AgentTuiInputRequest(input: .text("hello"))))
    let input = try #require(json["input"] as? [String: Any])
    #expect(input["type"] as? String == "text")
    #expect(input["text"] as? String == "hello")
    #expect(json["sequence"] == nil)
  }
}
