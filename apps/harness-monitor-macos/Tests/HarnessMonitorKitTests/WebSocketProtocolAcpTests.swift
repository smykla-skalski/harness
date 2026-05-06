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
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
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
    #expect(batch.acpId == "acp-1")
    #expect(batch.expiresAt == "2026-04-28T00:05:00Z")
    #expect(batch.requests.first?.requestId == "request-1")
  }

  @Test("ACP permission batches encode explicit managed-agent identity aliases")
  func acpPermissionBatchEncodesExplicitManagedAgentIdentityAliases() throws {
    let batch = AcpPermissionBatch(
      batchId: "batch-1",
      acpId: "acp-1",
      sessionId: "session-1",
      requests: [],
      createdAt: "2026-04-28T00:00:00Z",
      expiresAt: "2026-04-28T00:05:00Z"
    )

    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let encoded = try encoder.encode(batch)
    let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(json["managed_agent_id"] as? String == "acp-1")
    #expect(json["managed_agent_family"] as? String == "acp")
    #expect(json["acp_id"] == nil)
  }

  @Test("Daemon push event rejects ACP permission batches without managed-agent family")
  func daemonPushEventRejectsAcpPermissionBatchWithoutManagedAgentFamily() {
    let json = """
      {
        "event": "acp_permission_requested",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:00Z",
        "payload": {
          "batch_id": "batch-1",
          "managed_agent_id": "acp-1",
          "session_id": "session-1",
          "created_at": "2026-04-28T00:00:00Z",
          "requests": []
        }
      }
      """

    #expect(throws: DecodingError.self) {
      let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
      _ = try DaemonPushEvent(streamEvent: streamEvent)
    }
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
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
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
    #expect(removal.batch.acpId == "acp-1")
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
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
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

  @Test("Daemon push event decodes ACP transcript rows")
  func daemonPushEventDecodesAcpTranscriptRows() throws {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-05-05T00:00:30Z",
        "payload": {
          "managed_agent_id": "acp-1",
          "managed_agent_family": "acp",
          "session_id": "session-1",
          "raw_count": 3,
          "events": [
            {
              "timestamp": "2026-05-05T00:00:00Z",
              "sequence": 1,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "watchdog_state",
                "from": "active",
                "to": "paused",
                "reason": "client_idle"
              }
            },
            {
              "timestamp": "2026-05-05T00:00:01Z",
              "sequence": 2,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "permission_asked",
                "tool": "write_file",
                "scope": "src/lib.rs",
                "request_id": "req-1"
              }
            },
            {
              "timestamp": "2026-05-05T00:00:02Z",
              "sequence": 3,
              "agent": "copilot",
              "session_id": "session-1",
              "kind": {
                "type": "context_injected",
                "actor": "acp",
                "summary": "wake prompt accepted (signal sig-1)"
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
    #expect(
      entries.map(\.kind) == [
        "agent_watchdog_state",
        "agent_permission_asked",
        "agent_context_injected",
      ]
    )
    #expect(entries[0].summary == "copilot watchdog active -> paused (client_idle)")
    #expect(entries[1].summary == "copilot asked for permission on write_file (src/lib.rs)")
    #expect(
      entries[2].summary
        == "copilot received context from acp: wake prompt accepted (signal sig-1)"
    )
    #expect(entries[0].entryId == "acp-copilot-agent_watchdog_state-1")
    #expect(entries[1].entryId == "acp-copilot-agent_permission_asked-2")
    #expect(entries[2].entryId == "acp-copilot-agent_context_injected-3")
  }

  @Test("Daemon push event rejects ACP events with non-ACP managed-agent family")
  func daemonPushEventRejectsAcpEventsWithWrongManagedAgentFamily() {
    let json = """
      {
        "event": "acp_events",
        "session_id": "session-1",
        "recorded_at": "2026-04-28T00:00:30Z",
        "payload": {
          "managed_agent_id": "acp-1",
          "managed_agent_family": "tui",
          "session_id": "session-1",
          "raw_count": 1,
          "events": []
        }
      }
      """

    #expect(throws: DecodingError.self) {
      let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
      _ = try DaemonPushEvent(streamEvent: streamEvent)
    }
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

}
