import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for TriageRuleSetV1 and its store/protocol response types,
/// generated from src/task_board/triage_rules.rs, its `store` submodule, and
/// src/daemon/protocol/task_board_triage_rules.rs. These types ride bare, no
/// `*Wire` suffix, no `init(wire:)` mapping step -- this test is the decode
/// contract that keeps the generated file honest until `mise run codegen`
/// regenerates it.
@Suite("Task board triage rules wire types")
struct TaskBoardTriageRulesWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes every internally-tagged TriageRuleCondition variant")
  func decodesEveryConditionVariant() throws {
    let conditions = try decoder.decode(
      [TriageRuleCondition].self, from: Data(conditionsFixture.utf8))
    #expect(
      conditions == [
        .labelsHasAny(labels: ["kind/bug"]),
        .labelsHasAll(labels: ["kind/bug", "area/ui"]),
        .labelsHasNone(labels: ["triage/needs-info"]),
        .priorityEquals(priority: .high),
        .executionRepositoryEquals(value: "org/repo"),
        .executionRepositoryIsPresent,
        .executionRepositoryIsMissing,
        .projectIdEquals(value: "project-1"),
        .projectIdIsPresent,
        .projectIdIsMissing,
        .targetProjectTypesHasAny(types: ["kuma"]),
        .targetProjectTypesHasNone(types: ["unknown"]),
        .importedFromProviderEquals(provider: .gitHub),
        .importedFromProviderIsMissing,
      ])
  }

  @Test("decodes both TriagePriorityAction variants")
  func decodesPriorityActionVariants() throws {
    let keep = try decoder.decode(TriagePriorityAction.self, from: Data(#"{"action":"keep"}"#.utf8))
    let setTo = try decoder.decode(
      TriagePriorityAction.self, from: Data(#"{"action":"set_to","priority":"critical"}"#.utf8)
    )
    #expect(keep == .keep)
    #expect(setTo == .setTo(priority: .critical))
  }

  @Test("decodes a full TriageRuleSetV1 candidate")
  func decodesRuleSetCandidate() throws {
    let rules = try decoder.decode(TriageRuleSetV1.self, from: Data(ruleSetFixture.utf8))
    #expect(rules.schemaVersion == 1)
    #expect(rules.rules.count == 1)
    #expect(rules.rules[0].id == "urgent-bugs")
    #expect(rules.rules[0].when == [.priorityEquals(priority: .critical)])
    #expect(rules.rules[0].outcome.verdict == .todo)
    #expect(rules.rules[0].outcome.priorityAction == .setTo(priority: .critical))
    #expect(rules.defaultOutcome.verdict == .undecided)
    #expect(rules.defaultOutcome.priorityAction == .keep)
  }

  @Test("a rule with no `when` defaults to an empty condition list")
  func ruleWithoutWhenDefaultsToEmptyConditions() throws {
    let rule = try decoder.decode(
      TriageRule.self, from: Data(#"{"id":"catch-all","outcome":{"verdict":"todo"}}"#.utf8))
    #expect(rule.when.isEmpty)
    #expect(rule.outcome.priorityAction == .keep)
  }

  @Test("decodes a draft response with a populated draft")
  func decodesDraftResponseWithDraft() throws {
    let response = try decoder.decode(
      TaskBoardTriageRulesDraftResponse.self, from: Data(draftResponseFixture.utf8)
    )
    let draft = try #require(response.draft)
    #expect(draft.revision == 3)
    #expect(draft.actor == "operator-1")
    #expect(draft.updatedAt == "2026-07-24T00:00:00Z")
    #expect(draft.rules.rules.count == 1)
  }

  @Test("decodes a draft response with no draft yet")
  func decodesDraftResponseWithoutDraft() throws {
    let response = try decoder.decode(
      TaskBoardTriageRulesDraftResponse.self, from: Data(#"{}"#.utf8)
    )
    #expect(response.draft == nil)
  }

  @Test("decodes an activation result")
  func decodesActivationResult() throws {
    let result = try decoder.decode(
      TriageRuleSetActivationResult.self, from: Data(activationResultFixture.utf8)
    )
    #expect(result.validation.issues.isEmpty)
    #expect(result.activated)
    #expect(result.revision == 4)
    #expect(result.reevaluatedItemCount == 12)
  }

  @Test("decodes an activation result carrying validation issues")
  func decodesActivationResultWithValidationIssues() throws {
    let result = try decoder.decode(
      TriageRuleSetActivationResult.self, from: Data(rejectedActivationResultFixture.utf8)
    )
    #expect(!result.activated)
    #expect(result.revision == nil)
    #expect(
      result.validation.issues == [
        .duplicateRuleId(ruleId: "urgent-bugs"),
        .shadowedRule(ruleId: "later-rule", shadowedBy: "catch-all"),
      ]
    )
  }

  @Test("decodes a preview result and its diff entries")
  func decodesPreviewResult() throws {
    let result = try decoder.decode(
      TriageRuleSetPreviewResult.self, from: Data(previewResultFixture.utf8)
    )
    #expect(result.diff.count == 2)
    #expect(result.diff[0].itemId == "task-1")
    #expect(result.diff[0].liveEffectiveVerdict == .undecided)
    #expect(result.diff[0].liveEffectiveSource == .automatic)
    #expect(result.diff[0].candidateVerdict == .todo)
    #expect(result.diff[0].candidateMatchedRuleId == "urgent-bugs")
    #expect(result.diff[0].governsPlacementChange)
    #expect(result.diff[1].liveEffectiveVerdict == nil)
    #expect(result.diff[1].liveEffectiveSource == nil)
    #expect(!result.diff[1].governsPlacementChange)
  }

  @Test("decodes a revisions response ordered as sent")
  func decodesRevisionsResponse() throws {
    let response = try decoder.decode(
      TaskBoardTriageRulesRevisionsResponse.self, from: Data(revisionsResponseFixture.utf8)
    )
    #expect(response.revisions.count == 2)
    #expect(response.revisions[0].status == .active)
    #expect(response.revisions[0].supersededAt == nil)
    #expect(response.revisions[1].status == .superseded)
    #expect(response.revisions[1].supersededAt == "2026-07-24T00:00:00Z")
  }

  @Test("decodes an audit response including a rejected activation")
  func decodesAuditResponse() throws {
    let response = try decoder.decode(
      TaskBoardTriageRulesAuditResponse.self, from: Data(auditResponseFixture.utf8)
    )
    #expect(response.audit.count == 2)
    #expect(response.audit[0].kind == .activated)
    #expect(response.audit[0].reevaluatedItemCount == 12)
    #expect(response.audit[1].kind == .activationRejected)
    #expect(response.audit[1].revision == nil)
    #expect(response.audit[1].reason == "candidate failed validation")
  }
}

private let conditionsFixture = """
  [
    {"fact":"labels_has_any","labels":["kind/bug"]},
    {"fact":"labels_has_all","labels":["kind/bug","area/ui"]},
    {"fact":"labels_has_none","labels":["triage/needs-info"]},
    {"fact":"priority_equals","priority":"high"},
    {"fact":"execution_repository_equals","value":"org/repo"},
    {"fact":"execution_repository_is_present"},
    {"fact":"execution_repository_is_missing"},
    {"fact":"project_id_equals","value":"project-1"},
    {"fact":"project_id_is_present"},
    {"fact":"project_id_is_missing"},
    {"fact":"target_project_types_has_any","types":["kuma"]},
    {"fact":"target_project_types_has_none","types":["unknown"]},
    {"fact":"imported_from_provider_equals","provider":"github"},
    {"fact":"imported_from_provider_is_missing"}
  ]
  """

private let ruleSetFixture = """
  {
    "schema_version": 1,
    "rules": [
      {
        "id": "urgent-bugs",
        "when": [{"fact":"priority_equals","priority":"critical"}],
        "outcome": {
          "verdict": "todo",
          "priority_action": {"action":"set_to","priority":"critical"}
        }
      }
    ],
    "default_outcome": {"verdict": "undecided"}
  }
  """

private let draftResponseFixture = """
  {
    "draft": {
      "rules": \(ruleSetFixture),
      "revision": 3,
      "actor": "operator-1",
      "updated_at": "2026-07-24T00:00:00Z"
    }
  }
  """

private let activationResultFixture = """
  {
    "validation": {"issues": []},
    "activated": true,
    "revision": 4,
    "reevaluated_item_count": 12
  }
  """

private let rejectedActivationResultFixture = """
  {
    "validation": {
      "issues": [
        {"issue":"duplicate_rule_id","rule_id":"urgent-bugs"},
        {"issue":"shadowed_rule","rule_id":"later-rule","shadowed_by":"catch-all"}
      ]
    },
    "activated": false,
    "reevaluated_item_count": 0
  }
  """

private let previewResultFixture = """
  {
    "validation": {"issues": []},
    "diff": [
      {
        "item_id": "task-1",
        "live_effective_verdict": "undecided",
        "live_effective_source": "automatic",
        "candidate_verdict": "todo",
        "candidate_matched_rule_id": "urgent-bugs",
        "governs_placement_change": true
      },
      {
        "item_id": "task-2",
        "candidate_verdict": "undecided",
        "governs_placement_change": false
      }
    ]
  }
  """

private let revisionsResponseFixture = """
  {
    "revisions": [
      {
        "revision": 2,
        "schema_version": 1,
        "rule_count": 1,
        "status": "active",
        "actor": "operator-1",
        "activated_at": "2026-07-24T00:01:00Z"
      },
      {
        "revision": 1,
        "schema_version": 1,
        "rule_count": 0,
        "status": "superseded",
        "actor": "operator-1",
        "activated_at": "2026-07-24T00:00:00Z",
        "superseded_at": "2026-07-24T00:00:00Z"
      }
    ]
  }
  """

private let auditResponseFixture = """
  {
    "audit": [
      {
        "audit_id": "audit-1",
        "kind": "activated",
        "revision": 2,
        "actor": "operator-1",
        "reevaluated_item_count": 12,
        "recorded_at": "2026-07-24T00:01:00Z"
      },
      {
        "audit_id": "audit-2",
        "kind": "activation_rejected",
        "actor": "operator-1",
        "reason": "candidate failed validation",
        "recorded_at": "2026-07-24T00:00:30Z"
      }
    ]
  }
  """
