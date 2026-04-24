import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor task models v10")
struct HarnessMonitorTaskModelsTests {
  private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
  }()

  private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    return encoder
  }()

  @Test("TaskStatus decodes awaiting_review")
  func taskStatusDecodesAwaitingReview() throws {
    let data = Data("\"awaiting_review\"".utf8)
    let status = try decoder.decode(TaskStatus.self, from: data)
    #expect(status == .awaitingReview)
  }

  @Test("TaskSource decodes improver")
  func taskSourceDecodesImprover() throws {
    let data = Data("\"improver\"".utf8)
    let source = try decoder.decode(TaskSource.self, from: data)
    #expect(source == .improver)
  }

  @Test("ReviewVerdict decodes kebab-case alias")
  func reviewVerdictAcceptsKebabAlias() throws {
    let canonical = try decoder.decode(
      ReviewVerdict.self, from: Data("\"request_changes\"".utf8))
    let kebab = try decoder.decode(
      ReviewVerdict.self, from: Data("\"request-changes\"".utf8))
    #expect(canonical == .requestChanges)
    #expect(kebab == .requestChanges)
  }

  @Test("WorkItem decodes with absent v10 fields")
  func workItemDecodesWithoutV10Fields() throws {
    let json = """
      {
        "task_id": "t-1",
        "title": "legacy",
        "severity": "medium",
        "status": "open",
        "created_at": "2026-04-24T00:00:00Z",
        "updated_at": "2026-04-24T00:00:00Z"
      }
      """
    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(item.awaitingReview == nil)
    #expect(item.reviewClaim == nil)
    #expect(item.consensus == nil)
    #expect(item.arbitration == nil)
    #expect(item.reviewRound == 0)
    #expect(item.suggestedPersona == nil)
  }

  @Test("WorkItem decodes with v10 review fields present")
  func workItemDecodesV10Fields() throws {
    let json = """
      {
        "task_id": "t-1",
        "title": "review",
        "severity": "high",
        "status": "awaiting_review",
        "created_at": "2026-04-24T00:00:00Z",
        "updated_at": "2026-04-24T00:00:00Z",
        "review_round": 2,
        "suggested_persona": "reviewer",
        "awaiting_review": {
          "queued_at": "2026-04-24T00:01:00Z",
          "submitter_agent_id": "worker-1",
          "summary": "ready",
          "required_consensus": 2
        },
        "review_claim": {
          "reviewers": [
            {
              "reviewer_agent_id": "rev-claude",
              "reviewer_runtime": "claude",
              "claimed_at": "2026-04-24T00:02:00Z"
            }
          ]
        },
        "consensus": {
          "verdict": "approve",
          "summary": "LGTM",
          "closed_at": "2026-04-24T00:03:00Z",
          "reviewer_agent_ids": ["rev-claude", "rev-codex"]
        },
        "arbitration": {
          "arbiter_agent_id": "leader-1",
          "verdict": "approve",
          "summary": "final",
          "recorded_at": "2026-04-24T00:04:00Z"
        }
      }
      """
    let item = try decoder.decode(WorkItem.self, from: Data(json.utf8))
    #expect(item.status == .awaitingReview)
    #expect(item.reviewRound == 2)
    #expect(item.suggestedPersona == "reviewer")
    #expect(item.awaitingReview?.submitterAgentId == "worker-1")
    #expect(item.awaitingReview?.requiredConsensus == 2)
    #expect(item.reviewClaim?.reviewers.count == 1)
    #expect(item.reviewClaim?.reviewers.first?.reviewerRuntime == "claude")
    #expect(item.consensus?.verdict == .approve)
    #expect(item.consensus?.reviewerAgentIds.count == 2)
    #expect(item.arbitration?.verdict == .approve)
  }

  @Test("WorkItem roundtrips review fields")
  func workItemRoundtripsReviewFields() throws {
    let original = WorkItem(
      taskId: "t-rt",
      title: "round trip",
      context: nil,
      severity: .critical,
      status: .inReview,
      assignedTo: "worker-1",
      createdAt: "2026-04-24T00:00:00Z",
      updatedAt: "2026-04-24T00:00:00Z",
      createdBy: nil,
      notes: [],
      suggestedFix: nil,
      source: .improver,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil,
      awaitingReview: nil,
      reviewClaim: ReviewClaim(reviewers: [
        ReviewerEntry(
          reviewerAgentId: "rev-1",
          reviewerRuntime: "claude",
          claimedAt: "2026-04-24T00:02:00Z"
        )
      ]),
      consensus: nil,
      reviewRound: 1,
      arbitration: nil,
      suggestedPersona: "code-reviewer"
    )
    let data = try encoder.encode(original)
    let decoded = try decoder.decode(WorkItem.self, from: data)
    #expect(decoded.status == .inReview)
    #expect(decoded.source == .improver)
    #expect(decoded.reviewRound == 1)
    #expect(decoded.reviewClaim?.reviewers.first?.reviewerAgentId == "rev-1")
    #expect(decoded.suggestedPersona == "code-reviewer")
  }
}
