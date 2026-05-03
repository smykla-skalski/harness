import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("WebSocket ACP protocol wire format")
struct WebSocketProtocolAcpTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  @Test("Daemon push event decodes ACP permission request")
  func daemonPushEventDecodesAcpPermissionRequest() throws {
    let json = """
      {
        "event": "acp_permission_requested",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:00Z",
        "payload": {
          "batch_id": "batch-1",
          "acp_id": "acp-1",
          "session_id": "session-1",
          "created_at": "2026-04-28T00:00:00Z",
          "expires_at": "2026-04-28T00:05:00Z",
          "requests": [
            {
              "request_id": "request-1",
              "session_id": "session-1",
              "tool_call": { "name": "write_file", "path": "src/lib.rs" },
              "options": []
            }
          ]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpPermissionBatch(let batch) = event.kind else {
      Issue.record("Expected ACP permission batch, got \(event.kind)")
      return
    }
    #expect(batch.batchId == "batch-1")
    #expect(batch.expiresAt == "2026-04-28T00:05:00Z")
    #expect(batch.requests.first?.requestId == "request-1")
  }

  @Test("Daemon push event decodes ACP permission timeout as removal")
  func daemonPushEventDecodesAcpPermissionTimeoutAsRemoval() throws {
    let json = """
      {
        "event": "acp_permission_timeout",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:05:00Z",
        "payload": {
          "batch_id": "batch-1",
          "acp_id": "acp-1",
          "session_id": "session-1",
          "created_at": "2026-04-28T00:00:00Z",
          "expires_at": "2026-04-28T00:05:00Z",
          "requests": []
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpPermissionBatchRemoved(let removal) = event.kind else {
      Issue.record("Expected ACP permission removal, got \(event.kind)")
      return
    }
    #expect(removal.batch.batchId == "batch-1")
    #expect(removal.batch.expiresAt == "2026-04-28T00:05:00Z")
    #expect(removal.reason == .timeout)
  }

  @Test("Daemon push event decodes ACP events into timeline entries")
  func daemonPushEventDecodesAcpEventsIntoTimelineEntries() throws {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:30Z",
        "payload": {
          "acp_id": "acp-1",
          "session_id": "session-1",
          "raw_count": 2,
          "events": [
            {
              "timestamp": "2026-04-28T00:00:00Z",
              "sequence": 7,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "tool_invocation",
                "tool_name": "Write",
                "category": "edit",
                "input": { "path": "src/lib.rs" },
                "invocation_id": "call-1"
              }
            },
            {
              "timestamp": "2026-04-28T00:00:05Z",
              "sequence": 8,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "tool_result",
                "tool_name": "Write",
                "invocation_id": "call-1",
                "output": "ok",
                "is_error": false
              }
            }
          ]
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpEvents(let payload) = event.kind else {
      Issue.record("Expected ACP events, got \(event.kind)")
      return
    }
    let entries = payload.timelineEntries(fallbackRecordedAt: event.recordedAt)

    #expect(payload.acpId == "acp-1")
    #expect(payload.rawCount == 2)
    #expect(entries.map(\.kind) == ["tool_invocation", "tool_result"])
    #expect(entries[0].entryId == "acp-copilot-tool_invocation-7")
    guard case .object(let payloadObject) = entries[1].payload else {
      Issue.record("Expected ACP timeline payload object")
      return
    }
    #expect(payloadObject["runtime"] == .string("acp"))
    guard case .object(let timelineObject)? = payloadObject["tool_call_timeline"] else {
      Issue.record("Expected tool_call_timeline metadata")
      return
    }
    #expect(timelineObject["tool_call_id"] == .string("call-1"))
    #expect(timelineObject["status"] == .string("completed"))
  }

  @Test("Daemon push event decodes ACP inspect snapshots")
  func daemonPushEventDecodesAcpInspectSnapshots() throws {
    let json = """
      {
        "event": "acp_inspect",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:45Z",
        "payload": {
          "inspect": {
            "agents": [
              {
                "acp_id": "acp-1",
                "session_id": "session-1",
                "agent_id": "worker-codex",
                "display_name": "worker-codex",
                "pid": 41001,
                "pgid": 41001,
                "uptime_ms": 93000,
                "last_update_at": "2026-04-28T00:00:40Z",
                "last_client_call_at": "2026-04-28T00:00:35Z",
                "watchdog_state": "active",
                "permission_mode": "allow_edits",
                "pending_permissions": 2,
                "permission_queue_depth": 1,
                "terminal_count": 1,
                "prompt_deadline_remaining_ms": 45000
              }
            ]
          }
        }
      }
      """
    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)
    guard case .acpInspect(let response) = event.kind else {
      Issue.record("Expected ACP inspect, got \(event.kind)")
      return
    }
    let snapshot = try #require(response.agents.first)
    #expect(event.sessionId == "session-1")
    #expect(response.available)
    #expect(snapshot.agentId == "worker-codex")
    #expect(snapshot.pendingPermissions == 2)
    #expect(snapshot.promptDeadlineRemainingMs == 45_000)
  }

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
              "acp_id": "acp-1",
              "session_id": "session-1",
              "agent_id": "worker-codex",
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
                "acp_id": "acp-1",
                "session_id": "session-1",
                "agent_id": "worker-codex",
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
              "acp_id": "acp-1",
              "session_id": "session-1",
              "agent_id": "worker-codex",
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
