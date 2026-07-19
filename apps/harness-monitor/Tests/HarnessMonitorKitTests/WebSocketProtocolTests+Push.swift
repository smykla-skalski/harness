import Foundation
import Testing

@testable import HarnessMonitorKit

extension WebSocketProtocolTests {
  @Test("Daemon push event decodes session_updated with tagged ACP runtime")
  func sessionUpdatedDecodesTaggedAcpRuntime() throws {
    let json = #"""
      {
        "event": "session_updated",
        "recorded_at": "2026-05-01T17:00:00Z",
        "session_id": "sess-1",
        "payload": {
          "detail": {
            "session": {
              "project_id": "project-1",
              "project_name": "Harness",
              "project_dir": "/tmp/project",
              "context_root": "/tmp/context",
              "session_id": "sess-1",
              "worktree_path": "/tmp/worktree",
              "shared_path": "/tmp/shared",
              "origin_path": "/tmp/origin",
              "branch_ref": "main",
              "title": "Session",
              "context": "testing",
              "status": "active",
              "created_at": "2026-05-01T16:59:00Z",
              "updated_at": "2026-05-01T17:00:00Z",
              "last_activity_at": "2026-05-01T17:00:00Z",
              "leader_id": "leader-1",
              "observe_id": null,
              "pending_leader_transfer": null,
              "external_origin": null,
              "adopted_at": null,
              "metrics": {
                "agent_count": 2,
                "active_agent_count": 2,
                "idle_agent_count": 0,
                "awaiting_review_agent_count": 0,
                "open_task_count": 0,
                "in_progress_task_count": 0,
                "awaiting_review_task_count": 0,
                "in_review_task_count": 0,
                "arbitration_task_count": 0,
                "blocked_task_count": 0,
                "completed_task_count": 0
              }
            },
            "agents": [
              {
                "session_agent_id": "copilot-worker",
                "name": "GitHub Copilot",
                "runtime": {
                  "kind": "acp",
                  "id": "copilot"
                },
                "role": "worker",
                "capabilities": [],
                "joined_at": "2026-05-01T17:00:00Z",
                "updated_at": "2026-05-01T17:00:00Z",
                "status": "active",
                "runtime_session_id": "acp-session-1",
                "runtime_capabilities": {
                  "runtime": "copilot",
                  "supports_native_transcript": true,
                  "supports_signal_delivery": true,
                  "supports_context_injection": true,
                  "typical_signal_latency_seconds": 5,
                  "hook_points": []
                }
              }
            ],
            "tasks": [],
            "signals": [],
            "observer": null,
            "agent_activity": []
          },
          "timeline": null,
          "extensions_pending": true
        }
      }
      """#

    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)

    guard case .sessionUpdated(let payload) = event.kind else {
      Issue.record("Expected sessionUpdated event, got \(event.kind)")
      return
    }

    #expect(payload.detail.session.sessionId == "sess-1")
    #expect(payload.detail.agents.count == 1)
    #expect(payload.detail.agents.first?.runtime == "copilot")
    #expect(payload.extensionsPending == true)
  }

  @Test("Daemon push event decodes typed audit payloads")
  func daemonPushEventDecodesAuditEventPayload() throws {
    let json = #"""
      {
        "event": "audit_event",
        "recorded_at": "2026-06-01T15:00:00Z",
        "session_id": null,
        "payload": {
          "id": "audit-live-1",
          "recorded_at": "2026-06-01T15:00:00Z",
          "source": "github",
          "category": "githubMutation",
          "kind": "reviews.merge",
          "severity": "info",
          "outcome": "success",
          "title": "Merge pull request",
          "summary": "Merge pull request succeeded",
          "action_key": "reviews.merge",
          "related_urls": ["https://github.com/example/repo/pull/1"]
        }
      }
      """#

    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)

    guard case .auditEvent(let auditEvent) = event.kind else {
      Issue.record("Expected auditEvent push, got \(event.kind)")
      return
    }

    #expect(event.sessionId == nil)
    #expect(auditEvent.id == "audit-live-1")
    #expect(auditEvent.source == "github")
    #expect(auditEvent.actionKey == "reviews.merge")
  }

  @Test("Daemon push event decodes GitHub data changes")
  func daemonPushEventDecodesGitHubDataChange() throws {
    let json = #"""
      {
        "event": "github_data_changed",
        "recorded_at": "2026-07-11T10:00:00Z",
        "session_id": null,
        "payload": {
          "revision": 12,
          "operation": "task_board.github.update_issue"
        }
      }
      """#

    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)

    guard case .githubDataChanged(let payload) = event.kind else {
      Issue.record("Expected githubDataChanged push, got \(event.kind)")
      return
    }

    #expect(event.sessionId == nil)
    #expect(payload.revision == 12)
    #expect(payload.operation == "task_board.github.update_issue")
  }

  @Test("Daemon push event decodes scoped Task Board changes")
  func daemonPushEventDecodesTaskBoardChange() throws {
    let json = #"""
      {
        "event": "task_board_updated",
        "recorded_at": "2026-07-11T10:00:00Z",
        "session_id": null,
        "payload": {
          "revision": 14,
          "scopes": ["task_board:items", "task_board:orchestrator", "task_board:policy_pipeline"]
        }
      }
      """#

    let streamEvent = try decoder.decode(StreamEvent.self, from: Data(json.utf8))
    let event = try DaemonPushEvent(streamEvent: streamEvent)

    guard case .taskBoardUpdated(let payload) = event.kind else {
      Issue.record("Expected taskBoardUpdated push, got \(event.kind)")
      return
    }
    #expect(payload.revision == 14)
    #expect(
      payload.scopes
        == ["task_board:items", "task_board:orchestrator", "task_board:policy_pipeline"]
    )
    #expect(payload.automation == nil)
  }
}
