import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract for the BuiltInV1 triage decision record and its read
/// responses, generated from src/task_board/triage.rs and
/// src/daemon/protocol/task_board_triage.rs. Unlike the item/position/summary
/// clusters, none of these types collide with an existing hand model, so they
/// ride bare -- no `*Wire` suffix, no `init(wire:)` mapping step. This test is
/// the decode contract that keeps the eventual generated file honest until
/// `mise run codegen` regenerates it.
@Suite("Task board triage wire types")
struct TaskBoardTriageWireDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a current-decision response with a populated decision")
  func decodesCurrentResponseWithDecision() throws {
    let response = try decoder.decode(
      TaskBoardTriageCurrentResponse.self, from: Data(currentPayloadFixture.utf8)
    )
    let current = try #require(response.current)
    #expect(current.decisionId == "triage-00000000000000000000000000000000")
    #expect(current.itemId == "task-1")
    #expect(current.generation == 1)
    #expect(current.verdict == .undecided)
    #expect(current.reasonCode == .needsInfoLabel)
    #expect(current.reasonDetail == "triage/needs-info")
    #expect(current.evaluatorIdentity == "task_board.triage.builtin_v1")
    #expect(current.evaluatorVersion == 1)
    #expect(
      current.evidenceFingerprint
        == "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    )
    #expect(current.cause == .initial)
    #expect(current.decidedAt == "2026-07-23T00:00:00Z")
    #expect(current.supersededAt == nil)
  }

  @Test("decodes a current-decision response with no decision yet")
  func decodesCurrentResponseWithoutDecision() throws {
    let response = try decoder.decode(
      TaskBoardTriageCurrentResponse.self, from: Data(#"{}"#.utf8)
    )
    #expect(response.current == nil)
  }

  @Test("decodes a history response and its keyset cursor")
  func decodesHistoryResponse() throws {
    let response = try decoder.decode(
      TaskBoardTriageHistoryResponse.self, from: Data(historyPayloadFixture.utf8)
    )
    #expect(response.decisions.count == 2)
    #expect(response.decisions[0].generation == 2)
    #expect(response.decisions[0].reasonDetail == nil)
    #expect(
      response.decisions[0].evidenceFingerprint
        == "sha256:1111111111111111111111111111111111111111111111111111111111111111"
    )
    #expect(response.decisions[1].generation == 1)
    #expect(response.decisions[1].supersededAt == "2026-07-23T00:01:00Z")
    #expect(response.nextBeforeGeneration == 1)
  }
}

private let currentPayloadFixture = """
  {
    "current": {
      "decision_id": "triage-00000000000000000000000000000000",
      "item_id": "task-1",
      "generation": 1,
      "verdict": "undecided",
      "reason_code": "needs_info_label",
      "reason_detail": "triage/needs-info",
      "evaluator_identity": "task_board.triage.builtin_v1",
      "evaluator_version": 1,
      "evidence_fingerprint": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "cause": "initial",
      "decided_at": "2026-07-23T00:00:00Z"
    }
  }
  """

private let historyPayloadFixture = """
  {
    "decisions": [
      {
        "decision_id": "triage-00000000000000000000000000000001",
        "item_id": "task-1",
        "generation": 2,
        "verdict": "todo",
        "reason_code": "meaningful_label",
        "evaluator_identity": "task_board.triage.builtin_v1",
        "evaluator_version": 1,
        "evidence_fingerprint": "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        "cause": "fingerprint_changed",
        "decided_at": "2026-07-23T00:02:00Z"
      },
      {
        "decision_id": "triage-00000000000000000000000000000000",
        "item_id": "task-1",
        "generation": 1,
        "verdict": "undecided",
        "reason_code": "needs_info_label",
        "reason_detail": "triage/needs-info",
        "evaluator_identity": "task_board.triage.builtin_v1",
        "evaluator_version": 1,
        "evidence_fingerprint": "sha256:0000000000000000000000000000000000000000000000000000000000000000",
        "cause": "initial",
        "decided_at": "2026-07-23T00:00:00Z",
        "superseded_at": "2026-07-23T00:01:00Z"
      }
    ],
    "next_before_generation": 1
  }
  """
