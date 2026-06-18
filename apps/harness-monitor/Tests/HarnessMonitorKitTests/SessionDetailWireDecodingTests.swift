import Foundation
import Testing

@testable import HarnessMonitorKit

/// Capstone wire-contract regression for SessionDetail - the aggregate returned by every session
/// -mutation endpoint. SessionDetailWire is generated from summaries.rs and references each of the
/// six member *Wire types; SessionDetail(wire:) folds the whole tree onto the rich models. This
/// decodes a full daemon payload through PolicyWireCoding.decoder and asserts every member arrives,
/// exercising the member maps end-to-end under the plain decoder.
@Suite("Session detail wire decoding")
struct SessionDetailWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("a full session detail decodes and maps all six members")
  func fullSessionDetailMapsAllMembers() throws {
    let payload = #"""
      {
        "session": {
          "project_id": "p1", "project_name": "Proj", "context_root": "/r",
          "worktree_path": "/w", "shared_path": "", "origin_path": "", "branch_ref": "main",
          "session_id": "s1", "title": "T", "context": "ctx", "status": "active",
          "created_at": "2026-06-18T09:00:00Z", "updated_at": "2026-06-18T10:00:00Z",
          "metrics": {
            "agent_count": 1, "active_agent_count": 1, "idle_agent_count": 0,
            "awaiting_review_agent_count": 0, "open_task_count": 1, "in_progress_task_count": 0,
            "awaiting_review_task_count": 0, "in_review_task_count": 0, "arbitration_task_count": 0,
            "blocked_task_count": 0, "completed_task_count": 0
          }
        },
        "agents": [{
          "session_agent_id": "a1", "name": "Worker", "runtime": "claude", "role": "worker",
          "joined_at": "2026-06-18T09:00:00Z", "updated_at": "2026-06-18T10:00:00Z",
          "status": "active",
          "runtime_capabilities": {
            "runtime": "claude", "supports_native_transcript": false,
            "supports_signal_delivery": false, "supports_context_injection": false,
            "typical_signal_latency_seconds": 0
          }
        }],
        "tasks": [{
          "task_id": "t1", "title": "Task", "severity": "high", "status": "open",
          "created_at": "2026-06-18T09:00:00Z", "updated_at": "2026-06-18T10:00:00Z"
        }],
        "signals": [{
          "runtime": "claude", "agent_id": "a1", "session_id": "s1", "status": "delivered",
          "signal": {
            "signal_id": "sig1", "version": 1, "created_at": "2026-06-18T09:00:00Z",
            "expires_at": "2026-06-18T11:00:00Z", "source_agent": "leader", "command": "start",
            "priority": "normal", "payload": {"message": "go"}, "delivery": {"max_retries": 0}
          }
        }],
        "observer": {
          "observe_id": "o1", "last_scan_time": "2026-06-18T10:00:00Z",
          "open_issue_count": 0, "resolved_issue_count": 0, "muted_code_count": 0,
          "active_worker_count": 0, "open_issues": [], "muted_codes": [], "active_workers": [],
          "agent_sessions": []
        },
        "agent_activity": [{
          "agent_id": "a1", "runtime": "claude", "tool_invocation_count": 3,
          "tool_result_count": 2, "tool_error_count": 0, "recent_tools": ["bash"]
        }]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(SessionDetailWire.self, from: data)
    let detail = try SessionDetail(wire: wire)

    #expect(detail.session.sessionId == "s1")
    #expect(detail.session.metrics.agentCount == 1)
    #expect(detail.agents.count == 1)
    #expect(detail.agents.first?.agentId == "a1")
    #expect(detail.agents.first?.runtime == "claude")
    #expect(detail.tasks.count == 1)
    #expect(detail.tasks.first?.taskId == "t1")
    #expect(detail.tasks.first?.severity == .high)
    #expect(detail.signals.count == 1)
    #expect(detail.signals.first?.status == .delivered)
    #expect(detail.observer?.observeId == "o1")
    #expect(detail.agentActivity.count == 1)
    #expect(detail.agentActivity.first?.toolInvocationCount == 3)
  }

  @Test("an empty session detail decodes with no observer")
  func emptySessionDetailDecodes() throws {
    let payload = #"""
      {
        "session": {
          "project_id": "p1", "project_name": "Proj", "context_root": "", "worktree_path": "",
          "shared_path": "", "origin_path": "", "branch_ref": "", "session_id": "s1",
          "title": "", "context": "", "status": "awaiting_leader",
          "created_at": "2026-06-18T09:00:00Z", "updated_at": "2026-06-18T09:00:00Z",
          "metrics": {
            "agent_count": 0, "active_agent_count": 0, "idle_agent_count": 0,
            "awaiting_review_agent_count": 0, "open_task_count": 0, "in_progress_task_count": 0,
            "awaiting_review_task_count": 0, "in_review_task_count": 0, "arbitration_task_count": 0,
            "blocked_task_count": 0, "completed_task_count": 0
          }
        },
        "agents": [], "tasks": [], "signals": [], "agent_activity": []
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(SessionDetailWire.self, from: data)
    let detail = try SessionDetail(wire: wire)

    #expect(detail.session.status == .awaitingLeader)
    #expect(detail.agents.isEmpty)
    #expect(detail.tasks.isEmpty)
    #expect(detail.signals.isEmpty)
    #expect(detail.observer == nil)
    #expect(detail.agentActivity.isEmpty)
  }
}
