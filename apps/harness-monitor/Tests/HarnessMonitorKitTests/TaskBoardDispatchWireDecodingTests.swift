import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the task-board dispatch graph, generated from dispatch.rs plus
/// policy.rs. The internally-tagged enums (readiness, block-reason, session-intent,
/// policy-decision) decode through the plain decoder as Swift enums with associated
/// values; the daemon's lifecycle and failures fields are dropped via
/// OMITTED_WIRE_FIELDS and ignored on decode. generate-only - mapping + reroute follow.
@Suite("Task board dispatch wire type")
struct TaskBoardDispatchWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a blocked plan through the tagged readiness, reason and decision")
  func decodesBlockedPlan() throws {
    let wire = try decoder.decode(
      DispatchExecutionSummaryWire.self, from: Data(dispatchSummaryFixture.utf8)
    )
    #expect(wire.plans.count == 1)
    let plan = try #require(wire.plans.first)
    #expect(plan.boardItemId == "task-1")

    guard case .blocked(let reason) = plan.readiness else {
      Issue.record("expected a blocked readiness")
      return
    }
    guard case .policy(let decision) = reason else {
      Issue.record("expected a policy block reason")
      return
    }
    guard case .deny(let reasonCode, let policyVersion) = decision else {
      Issue.record("expected a deny decision")
      return
    }
    #expect(reasonCode == .checksNotGreen)
    #expect(policyVersion == "v3")

    guard case .create(let title, _, let projectId) = plan.session else {
      Issue.record("expected a create session intent")
      return
    }
    #expect(title == "Fix the bug")
    #expect(projectId == "owner/repo")
    #expect(plan.worker.mode == .headless)
    #expect(plan.reviewer.phase == .afterWorkerReview)
    #expect(plan.task.severity == .medium)
  }

  @Test("decodes an applied task carrying the nested item wire")
  func decodesAppliedTask() throws {
    let wire = try decoder.decode(
      DispatchExecutionSummaryWire.self, from: Data(dispatchSummaryFixture.utf8)
    )
    let applied = try #require(wire.applied.first)
    #expect(applied.boardItemId == "task-9")
    #expect(applied.item.id == "task-9")
  }
}

private let dispatchSummaryFixture = """
  {
    "plans": [
      {
        "board_item_id": "task-1",
        "readiness": {
          "state": "blocked",
          "reason": {
            "kind": "policy",
            "decision": { "decision": "deny", "reason_code": "checks_not_green", "policy_version": "v3" }
          }
        },
        "session": { "kind": "create", "title": "Fix the bug", "context": null, "project_id": "owner/repo" },
        "task": { "title": "Fix the bug", "severity": "medium", "source": "manual", "tags": [], "external_refs": [] },
        "worker": { "mode": "headless" },
        "reviewer": { "phase": "after_worker_review", "suggested_persona": "code-reviewer", "required_consensus": 2 },
        "evaluator": { "phase": "after_worker_review", "mode": "headless" },
        "policy": { "decision": "deny", "reason_code": "checks_not_green", "policy_version": "v3" },
        "lifecycle": { "worker": {}, "reviewer": {}, "evaluator": {} }
      }
    ],
    "applied": [
      {
        "board_item_id": "task-9",
        "session_id": "sig-9",
        "work_item_id": "wi-9",
        "item": {
          "schema_version": 1, "id": "task-9", "title": "Done",
          "status": "done", "created_at": "a", "updated_at": "b"
        },
        "lifecycle": { "worker": {}, "reviewer": {}, "evaluator": {} }
      }
    ],
    "failures": [ { "board_item_id": "task-3", "kind": "create_session", "message": "boom" } ]
  }
  """
