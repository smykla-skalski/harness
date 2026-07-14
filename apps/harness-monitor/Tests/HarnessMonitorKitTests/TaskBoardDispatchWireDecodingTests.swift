import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract and mapping for the task-board dispatch graph, generated from
/// dispatch.rs. The internally-tagged enums (readiness, block-reason, session-intent,
/// policy-decision) decode through the plain decoder as Swift enums with associated
/// values and flatten into the hand discriminator structs; the daemon's lifecycle and
/// failures are dropped via OMITTED_WIRE_FIELDS. The dispatch endpoint is rerouted.
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

  @Test("maps a decoded dispatch summary to the rich hand model")
  func mapsDispatchSummary() throws {
    let wire = try decoder.decode(
      DispatchExecutionSummaryWire.self, from: Data(dispatchSummaryFixture.utf8)
    )
    let summary = TaskBoardDispatchSummary(wire: wire)

    #expect(summary.plans.count == 1)
    let plan = try #require(summary.plans.first)
    #expect(plan.boardItemId == "task-1")
    #expect(plan.renderedPrompt == "Implement task-1 exactly")
    #expect(plan.policyDecisionId == "decision-1")
    #expect(plan.readiness.state == "blocked")
    #expect(plan.readiness.reason?.kind == "policy")
    #expect(plan.readiness.reason?.decision?.decision == "deny")
    #expect(plan.readiness.reason?.decision?.reasonCode == "checks_not_green")
    #expect(plan.session.kind == "create")
    #expect(plan.session.title == "Fix the bug")
    #expect(plan.policy?.decision == "deny")
    #expect(plan.task.severity == .medium)
    #expect(plan.reviewer.phase == "after_worker_review")

    let applied = try #require(summary.applied.first)
    #expect(applied.boardItemId == "task-9")
    #expect(applied.item.id == "task-9")
  }

  @Test("maps pick and deliver responses with the exact rendered prompt")
  func mapsStepRouteResponses() throws {
    let pickWire = try decoder.decode(
      TaskBoardDispatchPickResponse.self,
      from: Data(dispatchPickFixture.utf8)
    )
    let pick = TaskBoardDispatchPickResult(wire: pickWire)
    #expect(pick.selection?.item.id == "task-1")
    #expect(pick.selection?.plan.renderedPrompt == "Implement task-1 exactly")
    #expect(pick.selection?.plan.policyDecisionId == "decision-1")

    let deliverWire = try decoder.decode(
      TaskBoardDispatchDeliverResponse.self,
      from: Data(dispatchDeliverFixture.utf8)
    )
    let delivery = try TaskBoardDispatchDelivery(wire: deliverWire)
    #expect(delivery.intentId == "intent-1")
    #expect(delivery.applied.boardItemId == "task-1")
    #expect(delivery.renderedPrompt == "Implement task-1 exactly")
    #expect(delivery.startedAgent == nil)
  }
}

private let dispatchPickFixture = """
  {
    "selection": {
      "item": {
        "schema_version": 1, "id": "task-1", "title": "Fix the bug",
        "status": "todo", "created_at": "a", "updated_at": "b"
      },
      "plan": {
        "board_item_id": "task-1",
        "rendered_prompt": "Implement task-1 exactly",
        "readiness": {
          "state": "blocked",
          "reason": {
            "kind": "policy",
            "decision": {
              "decision": "deny", "reason_code": "checks_not_green",
              "policy_version": "v3"
            }
          }
        },
        "session": {
          "kind": "create", "title": "Fix the bug", "context": null,
          "project_id": "owner/repo"
        },
        "task": {
          "title": "Fix the bug", "severity": "medium", "source": "manual",
          "tags": [], "external_refs": []
        },
        "worker": {"mode": "headless"},
        "reviewer": {
          "phase": "after_worker_review", "suggested_persona": "code-reviewer",
          "required_consensus": 2
        },
        "evaluator": {"phase": "after_worker_review", "mode": "headless"},
        "policy": {
          "decision": "deny", "reason_code": "checks_not_green",
          "policy_version": "v3"
        },
        "policy_decision_id": "decision-1",
        "lifecycle": {"worker": {}, "reviewer": {}, "evaluator": {}}
      }
    }
  }
  """

private let dispatchDeliverFixture = """
  {
    "intent_id": "intent-1",
    "applied": {
      "board_item_id": "task-1", "session_id": "session-1", "work_item_id": "work-1",
      "item": {
        "schema_version": 1, "id": "task-1", "title": "Fix the bug",
        "status": "in_progress", "created_at": "a", "updated_at": "b"
      },
      "lifecycle": {"worker": {}, "reviewer": {}, "evaluator": {}}
    },
    "rendered_prompt": "Implement task-1 exactly",
    "started_agent": null
  }
  """

private let dispatchSummaryFixture = """
  {
    "plans": [
      {
        "board_item_id": "task-1",
        "rendered_prompt": "Implement task-1 exactly",
        "readiness": {
          "state": "blocked",
          "reason": {
            "kind": "policy",
            "decision": { "decision": "deny", "reason_code": "checks_not_green", "policy_version": "v3" }
          }
        },
        "session": { "kind": "create", "title": "Fix the bug", "context": null, "project_id": "owner/repo" },
        "task": {
          "title": "Fix the bug", "severity": "medium", "source": "manual",
          "tags": [], "external_refs": []
        },
        "worker": { "mode": "headless" },
        "reviewer": {
          "phase": "after_worker_review", "suggested_persona": "code-reviewer",
          "required_consensus": 2
        },
        "evaluator": { "phase": "after_worker_review", "mode": "headless" },
        "policy": { "decision": "deny", "reason_code": "checks_not_green", "policy_version": "v3" },
        "policy_decision_id": "decision-1",
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
