import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the managed terminal agent protocol. The
/// AgentTui*Wire types are generated from src/daemon/agent_tui (model.rs +
/// screen.rs) and decode through the plain PolicyWireCoding.decoder; the app
/// models keep Int dimensions and computed helpers. These snapshots reach Swift
/// nested inside a ManagedAgentSnapshot, so this exercises the wire decode plus
/// mapping directly (the production reroute lands with the managed-agents
/// cluster). It also pins the `starting` status the hand enum previously could
/// not decode.
@Suite("Agent TUI wire types decoding")
struct AgentTuiWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  private let daemonSnapshot = #"""
    {
      "tui_id": "tui-1",
      "session_id": "eadbcb3e-6ef7-53d2-ad56-0347cb7189fc",
      "agent_id": "worker-1",
      "runtime": "claude",
      "status": "starting",
      "argv": ["claude"],
      "project_dir": "/tmp/project",
      "size": {"rows": 24, "cols": 80},
      "screen": {"rows": 24, "cols": 80, "cursor_row": 1, "cursor_col": 2, "text": "ready"},
      "transcript_path": "/tmp/transcript",
      "exit_code": null,
      "created_at": "2026-06-15T18:30:45Z",
      "updated_at": "2026-06-15T18:30:46Z"
    }
    """#

  @Test("decodes the daemon snapshot and maps it to the rich model")
  func decodesSnapshot() throws {
    let wire = try decoder.decode(AgentTuiSnapshotWire.self, from: Data(daemonSnapshot.utf8))
    let snapshot = AgentTuiSnapshot(wire: wire)

    #expect(snapshot.tuiId == "tui-1")
    #expect(snapshot.agentId == "worker-1")
    #expect(snapshot.runtime == "claude")
    #expect(snapshot.projectDir == "/tmp/project")
    #expect(snapshot.transcriptPath == "/tmp/transcript")
    #expect(snapshot.exitCode == nil)
    #expect(snapshot.size == AgentTuiSize(rows: 24, cols: 80))
    #expect(snapshot.screen.cursorRow == 1)
    #expect(snapshot.screen.cursorCol == 2)
    #expect(snapshot.screen.text == "ready")
  }

  @Test("maps the starting status the hand enum previously could not decode")
  func decodesStartingStatus() throws {
    let wire = try decoder.decode(AgentTuiSnapshotWire.self, from: Data(daemonSnapshot.utf8))
    let snapshot = AgentTuiSnapshot(wire: wire)
    #expect(snapshot.status == .starting)
    #expect(snapshot.status.isActive == true)
  }

  @Test("maps a start request to the wire type with snake_case keys")
  func mapsStartRequestToWire() throws {
    let request = AgentTuiStartRequest(
      runtime: "codex",
      role: .worker,
      taskID: "task-1",
      boardItemID: "board-1",
      workflowExecutionID: "wf-1",
      rows: 40,
      cols: 120
    )
    let wire = AgentTuiStartRequestWire(request)
    #expect(wire.rows == 40)
    #expect(wire.cols == 120)
    #expect(wire.fallbackRole == nil)

    let object = try #require(
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any]
    )
    #expect(object["task_id"] as? String == "task-1")
    #expect(object["board_item_id"] as? String == "board-1")
    #expect(object["workflow_execution_id"] as? String == "wf-1")
    #expect(object["allow_custom_model"] as? Bool == false)
  }
}
