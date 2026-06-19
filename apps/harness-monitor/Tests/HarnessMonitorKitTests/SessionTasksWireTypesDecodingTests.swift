import Foundation
import Testing

@testable import HarnessMonitorKit

/// Wire-contract regression for the session task types generated from
/// src/session/types/tasks.rs. The 10 review-flow structs own the snake_case
/// shape (explicit CodingKeys, plain decoder); this pins the WorkItem core
/// decode, its serde defaults (queue_policy/source fall back to the enum default,
/// notes/review_round/required_consensus to their zero values). The three plain
/// enums (TaskSeverity/TaskSource/ReviewPointState) are now generated bare and
/// decode here; TaskStatus/TaskQueuePolicy/ReviewVerdict stay hand because their
/// legacy-tolerant decode (in_progress AND legacy inProgress, etc.) a generated
/// plain enum would regress. Mapping these wire types to the rich hand models is a
/// follow-up.
@Suite("Session tasks wire types decoding")
struct SessionTasksWireTypesDecodingTests {
  private let decoder = PolicyWireCoding.decoder

  @Test("decodes a work item with its defaults and bare hand enums")
  func decodesWorkItem() throws {
    // queue_policy, source, notes and review_round are omitted, so they take
    // their serde defaults; status arrives snake_case and decodes through the
    // hand TaskStatus.
    let json = #"""
      {"task_id":"t-1","title":"Fix the parser","severity":"high","status":"in_progress",
      "created_at":"2026-06-15T00:00:00Z","updated_at":"2026-06-15T01:00:00Z"}
      """#
    let item = try decoder.decode(WorkItemWire.self, from: Data(json.utf8))

    #expect(item.taskId == "t-1")
    #expect(item.title == "Fix the parser")
    #expect(item.severity == .high)
    #expect(item.status == .inProgress)
    #expect(item.queuePolicy == .locked)
    #expect(item.source == .manual)
    #expect(item.notes.isEmpty)
    #expect(item.reviewRound == 0)
    #expect(item.context == nil)
  }

  @Test("decodes the awaiting-review struct defaulting required consensus to 2")
  func decodesAwaitingReviewDefault() throws {
    // required_consensus is omitted, so it resolves the default_required_consensus
    // fn (2) from the same file.
    let json = #"""
      {"queued_at":"2026-06-15T00:00:00Z","submitter_agent_id":"agent-1"}
      """#
    let awaiting = try decoder.decode(AwaitingReviewWire.self, from: Data(json.utf8))

    #expect(awaiting.submitterAgentId == "agent-1")
    #expect(awaiting.requiredConsensus == 2)
    #expect(awaiting.summary == nil)
  }

  @Test("decodes a review carrying its bare hand verdict enum")
  func decodesReview() throws {
    // points defaults to empty; verdict decodes through the bare hand ReviewVerdict.
    let json = #"""
      {"review_id":"r-1","round":1,"reviewer_agent_id":"agent-2","reviewer_runtime":"codex",
      "verdict":"approve","summary":"looks good","recorded_at":"2026-06-15T00:00:00Z"}
      """#
    let review = try decoder.decode(ReviewWire.self, from: Data(json.utf8))

    #expect(review.reviewId == "r-1")
    #expect(review.verdict == .approve)
    #expect(review.points.isEmpty)
  }

  @Test("decodes the three adopted enums and keeps their title")
  func decodesAdoptedEnums() throws {
    // The plain enums are generated bare now; each decodes from its snake_case
    // wire string and the .title computed prop survives as a Swift extension.
    #expect(try decoder.decode(TaskSeverity.self, from: Data(#""critical""#.utf8)) == .critical)
    #expect(try decoder.decode(TaskSource.self, from: Data(#""observe""#.utf8)) == .observe)
    #expect(try decoder.decode(ReviewPointState.self, from: Data(#""disputed""#.utf8)) == .disputed)

    #expect(TaskSeverity.high.title == "High")
    #expect(TaskSource.manual.title == "Manual")
    #expect(ReviewPointState.disputed.title == "Disputed")
  }
}
