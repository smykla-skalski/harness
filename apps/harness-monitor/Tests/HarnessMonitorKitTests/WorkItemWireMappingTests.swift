import Foundation
import Testing

@testable import HarnessMonitorKit

/// Map-contract regression for the SessionDetail.tasks member (WorkItem) and its review-flow tree.
/// WorkItemWire is generated with snake CodingKeys for the plain decoder; the map rides the
/// decoder-agnostic enums through bare, narrows the UInt8 counts to Int, maps the note/checkpoint
/// /review structs, and drops the unmodeled observe_issue_id + deleted_at.
@Suite("Work item wire mapping")
struct WorkItemWireMappingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("a full work item maps the review-flow tree and narrows the counts")
  func fullWorkItemMapsReviewFlow() throws {
    let payload = #"""
      {
        "task_id": "t1",
        "title": "Fix bug",
        "context": "ctx",
        "severity": "high",
        "status": "in_progress",
        "assigned_to": "a1",
        "queue_policy": "locked",
        "created_at": "2026-06-18T09:00:00Z",
        "updated_at": "2026-06-18T10:00:00Z",
        "created_by": "leader",
        "notes": [{"timestamp": "2026-06-18T09:30:00Z", "agent_id": "a1", "text": "looking"}],
        "suggested_fix": "guard the nil",
        "source": "observe",
        "observe_issue_id": "i1",
        "checkpoint_summary": {
          "checkpoint_id": "c1", "recorded_at": "2026-06-18T09:45:00Z", "actor_id": "a1",
          "summary": "halfway", "progress": 50
        },
        "awaiting_review": {
          "queued_at": "2026-06-18T09:50:00Z", "submitter_agent_id": "a1",
          "summary": "ready", "required_consensus": 2
        },
        "review_claim": {
          "reviewers": [{"reviewer_agent_id": "r1", "reviewer_runtime": "claude",
            "claimed_at": "2026-06-18T09:55:00Z"}]
        },
        "consensus": {
          "verdict": "approve", "summary": "lgtm",
          "points": [{"point_id": "p1", "text": "ok", "state": "agreed"}],
          "closed_at": "2026-06-18T10:00:00Z", "reviewer_agent_ids": ["r1"]
        },
        "review_history": [],
        "review_round": 1,
        "arbitration": {
          "arbiter_agent_id": "arb1", "verdict": "reject", "summary": "no",
          "recorded_at": "2026-06-18T10:05:00Z"
        },
        "suggested_persona": "reviewer",
        "deleted_at": null
      }
      """#
    let data = try #require(payload.data(using: .utf8))
    let wire = try decoder.decode(WorkItemWire.self, from: data)
    let item = WorkItem(wire: wire)

    #expect(item.taskId == "t1")
    #expect(item.severity == .high)
    #expect(item.status == .inProgress)
    #expect(item.queuePolicy == .locked)
    #expect(item.source == .observe)
    #expect(item.reviewRound == 1)
    #expect(item.notes.map(\.text) == ["looking"])
    #expect(item.checkpointSummary?.progress == 50)
    #expect(item.awaitingReview?.requiredConsensus == 2)
    #expect(item.reviewClaim?.reviewers.first?.reviewerAgentId == "r1")
    #expect(item.consensus?.verdict == .approve)
    #expect(item.consensus?.points.first?.state == .agreed)
    #expect(item.arbitration?.verdict == .reject)
    #expect(item.id == "t1")
  }
}
