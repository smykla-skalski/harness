import Foundation
import Testing

@testable import HarnessMonitorKit

/// Map-contract regression for three SessionDetail members whose generated wires were already in
/// the tree but had no wire -> model mapping: AgentToolActivitySummary, SessionSummary and
/// ObserverSummary. Each test decodes a byte-for-byte daemon member payload through
/// PolicyWireCoding.decoder and asserts the rich-model divergences the maps must handle (UInt
/// narrowing, the pending-prompt legacy fallback, and the observer open-enum rawValue extraction).
@Suite("Session detail member mapping")
struct SessionDetailMemberMappingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("agent tool activity narrows counts and replays the legacy prompt fallback")
  func agentToolActivityMapping() throws {
    let payload = #"""
      {
        "agent_id": "a1",
        "runtime": "claude",
        "tool_invocation_count": 5,
        "tool_result_count": 4,
        "tool_error_count": 1,
        "latest_tool_name": "bash",
        "latest_event_at": "2026-06-18T10:00:00Z",
        "recent_tools": ["bash", "edit"],
        "pending_user_prompt": {"tool_name": "ask", "message": "Proceed?", "questions": []}
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(AgentToolActivitySummaryWire.self, from: data)
    let summary = AgentToolActivitySummary(wire: wire)

    #expect(summary.toolInvocationCount == 5)
    #expect(summary.toolResultCount == 4)
    #expect(summary.toolErrorCount == 1)
    #expect(summary.recentTools == ["bash", "edit"])
    // The wire carries an empty questions list plus a legacy message, so the map synthesizes one.
    #expect(summary.pendingUserPrompt?.questions.map(\.question) == ["Proceed?"])
  }

  @Test("session summary narrows the metric counts")
  func sessionSummaryMapping() throws {
    let payload = #"""
      {
        "project_id": "p1",
        "project_name": "Proj",
        "context_root": "/r",
        "worktree_path": "/w",
        "shared_path": "",
        "origin_path": "",
        "branch_ref": "main",
        "session_id": "s1",
        "title": "Title",
        "context": "ctx",
        "status": "active",
        "created_at": "2026-06-18T09:00:00Z",
        "updated_at": "2026-06-18T10:00:00Z",
        "pending_leader_transfer": {
          "requested_by": "a1", "current_leader_id": "a0", "new_leader_id": "a2",
          "requested_at": "2026-06-18T09:30:00Z", "reason": "handoff"
        },
        "metrics": {
          "agent_count": 3, "active_agent_count": 2, "idle_agent_count": 1,
          "awaiting_review_agent_count": 0, "open_task_count": 4, "in_progress_task_count": 1,
          "awaiting_review_task_count": 0, "in_review_task_count": 1, "arbitration_task_count": 0,
          "blocked_task_count": 0, "completed_task_count": 7
        }
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(SessionSummaryWire.self, from: data)
    let summary = SessionSummary(wire: wire)

    #expect(summary.sessionId == "s1")
    #expect(summary.status == .active)
    #expect(summary.metrics.agentCount == 3)
    #expect(summary.metrics.completedTaskCount == 7)
    #expect(summary.pendingLeaderTransfer?.newLeaderId == "a2")
  }

  @Test("observer summary extracts open-enum raw values and narrows line counts")
  func observerSummaryMapping() throws {
    let payload = #"""
      {
        "observe_id": "o1",
        "last_scan_time": "2026-06-18T10:00:00Z",
        "open_issue_count": 2,
        "resolved_issue_count": 1,
        "muted_code_count": 1,
        "active_worker_count": 1,
        "open_issues": [
          {
            "issue_id": "i1", "code": "missing_error_handling", "severity": "warning",
            "category": "correctness", "summary": "No guard", "fingerprint": "fp1",
            "first_seen_line": 10, "occurrence_count": 3, "last_seen_line": 12,
            "fix_safety": "safe", "evidence_excerpt": null
          }
        ],
        "muted_codes": ["style_nit"],
        "active_workers": [
          {"issue_id": "i1", "target_file": "a.rs", "started_at": "2026-06-18T10:01:00Z",
           "agent_id": "a1", "runtime": "claude"}
        ],
        "agent_sessions": [
          {"agent_id": "a1", "runtime": "claude", "log_path": "/l", "cursor": 42,
           "last_activity": "2026-06-18T10:02:00Z"}
        ]
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(ObserverSummaryWire.self, from: data)
    let summary = ObserverSummary(wire: wire)

    #expect(summary.openIssueCount == 2)
    #expect(summary.mutedCodes == ["style_nit"])
    let issue = try #require(summary.openIssues?.first)
    #expect(issue.code == "missing_error_handling")
    #expect(issue.severity == "warning")
    #expect(issue.firstSeenLine == 10)
    #expect(issue.occurrenceCount == 3)
    #expect(issue.fixSafety == "safe")
    #expect(summary.agentSessions?.first?.cursor == 42)
  }
}
