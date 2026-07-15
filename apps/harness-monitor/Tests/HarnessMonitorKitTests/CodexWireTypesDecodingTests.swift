import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the codex run protocol. The Codex*Wire types are
/// generated from src/daemon/protocol/codex.rs and decode through the plain
/// PolicyWireCoding.decoder; the app models keep their Identifiable conformances,
/// computed helpers, and Int counts. CodexRunSnapshot reaches Swift nested inside
/// a ManagedAgentSnapshot, so this exercises the wire decode plus mapping directly
/// (the production reroute lands with the managed-agents cluster). It pins the
/// serde_json::Value event payload surviving the round trip and the run-request
/// snake_case encode keys.
@Suite("Codex wire types decoding")
struct CodexWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private let daemonRun = #"""
    {
      "run_id": "run-1",
      "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
      "task_id": "task-1",
      "board_item_id": "board-1",
      "workflow_execution_id": "workflow-1",
      "session_agent_id": "worker-codex",
      "display_name": "Codex",
      "project_dir": "/tmp/project",
      "thread_id": null,
      "turn_id": null,
      "mode": "report",
      "status": "running",
      "prompt": "investigate",
      "latest_summary": null,
      "final_message": null,
      "error": null,
      "pending_approvals": [
        {
          "approval_id": "ap-1", "request_id": "rq-1", "kind": "exec",
          "title": "Run command", "detail": "ls -la", "thread_id": null,
          "turn_id": null, "item_id": null, "cwd": "/tmp", "command": "ls -la",
          "file_path": null
        }
      ],
      "resolved_approvals": [],
      "events": [
        {
          "event_id": "ev-1", "sequence": 7, "recorded_at": "2026-06-15T18:30:45Z",
          "kind": "item.completed", "summary": "ran", "thread_id": null,
          "turn_id": null, "item_id": "it-1", "payload": {"nested": {"depth": 2}}
        }
      ],
      "created_at": "2026-06-15T18:30:45Z",
      "updated_at": "2026-06-15T18:30:46Z",
      "model": "gpt-5-codex",
      "effort": "high"
    }
    """#

  @Test("decodes the daemon run snapshot and maps it to the rich model")
  func decodesRunSnapshot() throws {
    let wire = try decoder.decode(CodexRunSnapshotWire.self, from: Data(daemonRun.utf8))
    let run = CodexRunSnapshot(wire: wire)

    #expect(run.runId == "run-1")
    #expect(run.taskId == "task-1")
    #expect(run.boardItemId == "board-1")
    #expect(run.workflowExecutionId == "workflow-1")
    #expect(run.sessionAgentId == "worker-codex")
    #expect(run.mode == .report)
    #expect(run.status == .running)
    #expect(run.status.isActive == true)
    #expect(run.model == "gpt-5-codex")
    #expect(run.pendingApprovals.count == 1)
    #expect(run.pendingApprovals.first?.command == "ls -la")
    #expect(run.resolvedApprovals.isEmpty)
    #expect(run.events.count == 1)
    #expect(run.events.first?.sequence == 7)
  }

  @Test("preserves the serde_json::Value event payload through decode and mapping")
  func preservesEventPayload() throws {
    let wire = try decoder.decode(CodexRunSnapshotWire.self, from: Data(daemonRun.utf8))
    let run = CodexRunSnapshot(wire: wire)

    let payload = try #require(run.events.first?.payload)
    let expected = try decoder.decode(JSONValue.self, from: Data(#"{"nested":{"depth":2}}"#.utf8))
    #expect(payload == expected)
  }

  @Test("maps a run request to the wire type with snake_case keys and the role default")
  func mapsRunRequestToWire() throws {
    let request = CodexRunRequest(
      actor: nil,
      prompt: "investigate",
      mode: .report,
      taskID: "task-1",
      boardItemID: "board-1",
      workflowExecutionID: "wf-1"
    )
    let wire = CodexRunRequestWire(request)
    #expect(wire.role == .worker)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["task_id"] as? String == "task-1")
    #expect(object["board_item_id"] as? String == "board-1")
    #expect(object["workflow_execution_id"] as? String == "wf-1")
    #expect(object["allow_custom_model"] as? Bool == false)
    #expect(object["role"] as? String == "worker")
  }
}
