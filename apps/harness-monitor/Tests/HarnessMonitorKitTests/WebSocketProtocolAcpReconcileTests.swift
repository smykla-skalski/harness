import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket ACP protocol wire format")
struct WebSocketProtocolAcpReconcileTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("Daemon push event decodes ACP reconcile payload with inline inspect telemetry")
  func daemonPushEventDecodesAcpReconcileInlineInspectTelemetry() throws {
    let json = """
      {
        "event": "acp_agents_reconciled",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:01:00Z",
        "payload": {
          "session_id": "session-1",
          "agents": [
            {
              "managed_agent_id": "acp-1",
              "managed_agent_family": "acp",
              "session_id": "session-1",
              "session_agent_id": "worker-codex",
              "display_name": "worker-codex",
              "status": "active",
              "pid": 41001,
              "pgid": 41001,
              "project_dir": "/tmp/project",
              "process_key": "pk-1",
              "pending_permissions": 0,
              "permission_queue_depth": 0,
              "pending_permission_batches": [],
              "permission_mode": "allow_edits",
              "permission_log_path": null,
              "terminal_count": 1,
              "created_at": "2026-04-28T00:00:00Z",
              "updated_at": "2026-04-28T00:00:45Z"
            }
          ],
          "inspect": {
            "agents": [
              {
                "managed_agent_id": "acp-1",
                "managed_agent_family": "acp",
                "session_id": "session-1",
                "session_agent_id": "worker-codex",
                "display_name": "worker-codex",
                "pid": 41001,
                "pgid": 41001,
                "uptime_ms": 93000,
                "last_update_at": "2026-04-28T00:00:40Z",
                "last_client_call_at": "2026-04-28T00:00:35Z",
                "watchdog_state": "active",
                "permission_mode": "allow_edits",
                "pending_permissions": 0,
                "permission_queue_depth": 0,
                "terminal_count": 1,
                "prompt_deadline_remaining_ms": 0
              }
            ]
          }
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpAgentsReconciled(let payload) = event.kind else {
      Issue.record("Expected ACP reconcile, got \(event.kind)")
      return
    }
    #expect(payload.sessionId == "session-1")
    #expect(payload.inspect?.available == true)
    #expect(payload.inspect?.agents.first?.agentId == "worker-codex")
  }

  @Test("Daemon push event decodes ACP reconcile payload without inline inspect telemetry")
  func daemonPushEventDecodesAcpReconcileWithoutInlineInspectTelemetry() throws {
    let json = """
      {
        "event": "acp_agents_reconciled",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:01:00Z",
        "payload": {
          "session_id": "session-1",
          "agents": [
            {
              "managed_agent_id": "acp-1",
              "managed_agent_family": "acp",
              "session_id": "session-1",
              "session_agent_id": "worker-codex",
              "display_name": "worker-codex",
              "status": "active",
              "pid": 41001,
              "pgid": 41001,
              "project_dir": "/tmp/project",
              "process_key": "pk-1",
              "pending_permissions": 0,
              "permission_queue_depth": 0,
              "pending_permission_batches": [],
              "permission_mode": "allow_edits",
              "permission_log_path": null,
              "terminal_count": 1,
              "created_at": "2026-04-28T00:00:00Z",
              "updated_at": "2026-04-28T00:00:45Z"
            }
          ]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpAgentsReconciled(let payload) = event.kind else {
      Issue.record("Expected ACP reconcile, got \(event.kind)")
      return
    }

    #expect(payload.sessionId == "session-1")
    #expect(payload.agents.map(\.agentId) == ["worker-codex"])
    #expect(payload.inspect == nil)
  }

  @Test("Daemon push event decodes sessionless ACP bridge resync incident")
  func daemonPushEventDecodesSessionlessAcpBridgeResyncIncident() throws {
    let json = """
      {
        "event": "acp_bridge_resync_incident",
        "recorded_at": "2026-04-28T00:10:00Z",
        "payload": {
          "kind": "protocol_desync",
          "bridge_epoch": "epoch-1",
          "continuity": 8,
          "next_seq": 19,
          "truncated": false,
          "affected_logical_session_ids": []
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpBridgeResyncIncident(let payload) = event.kind else {
      Issue.record("Expected ACP bridge resync incident, got \(event.kind)")
      return
    }
    #expect(event.sessionId == nil)
    #expect(payload.kind == "protocol_desync")
    #expect(payload.bridgeEpoch == "epoch-1")
    #expect(payload.continuity == 8)
  }

  @Test("Daemon push event decodes ACP process incident")
  func daemonPushEventDecodesAcpProcessIncident() throws {
    let json = """
      {
        "event": "acp_process_incident",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:10:00Z",
        "payload": {
          "kind": "transport_closed",
          "reason_kind": "transport_closed",
          "process_key": "acp-process-1",
          "pid": 42,
          "pgid": 42,
          "exit_code": null,
          "exit_signal": null,
          "stderr_tail": "lost transport",
          "affected_logical_session_ids": ["session-1"]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpProcessIncident(let payload) = event.kind else {
      Issue.record("Expected ACP process incident, got \(event.kind)")
      return
    }
    #expect(event.sessionId == "session-1")
    #expect(payload.kind == "transport_closed")
    #expect(payload.reasonKind == "transport_closed")
    #expect(payload.affectedLogicalSessionIds == ["session-1"])
  }
}
