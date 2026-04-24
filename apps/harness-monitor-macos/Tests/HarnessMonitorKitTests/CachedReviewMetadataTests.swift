import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("V8 review metadata cache round-trip")
struct CachedReviewMetadataTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  @Test("Review workflow state round-trips through V8 metadata side-table")
  func reviewMetadataRoundTrip() throws {
    let reviewerEntry = ReviewerEntry(
      reviewerAgentId: "reviewer-claude",
      reviewerRuntime: "claude",
      claimedAt: "2026-03-28T11:30:00Z",
      submittedAt: "2026-03-28T12:10:00Z"
    )
    let claim = ReviewClaim(reviewers: [reviewerEntry])
    let awaiting = AwaitingReview(
      queuedAt: "2026-03-28T11:00:00Z",
      submitterAgentId: "worker-1",
      summary: "ready for review",
      requiredConsensus: 2
    )
    let consensusPoint = ReviewPoint(
      pointId: "p1",
      text: "rename the helper",
      state: .agreed,
      workerNote: "sure"
    )
    let consensus = ReviewConsensus(
      verdict: .approve,
      summary: "LGTM",
      points: [consensusPoint],
      closedAt: "2026-03-28T12:30:00Z",
      reviewerAgentIds: ["reviewer-claude", "reviewer-codex"]
    )
    let history = ReviewConsensus(
      verdict: .requestChanges,
      summary: "needs round 1 rework",
      points: [consensusPoint],
      closedAt: "2026-03-28T11:45:00Z",
      reviewerAgentIds: ["reviewer-claude"]
    )
    let arbitration = ArbitrationOutcome(
      arbiterAgentId: "leader",
      verdict: .approve,
      summary: "shipping it",
      recordedAt: "2026-03-28T13:00:00Z"
    )

    let original = WorkItem(
      taskId: "task-review",
      title: "Tighten the quorum path",
      context: nil,
      severity: .high,
      status: .awaitingReview,
      assignedTo: nil,
      queuePolicy: .locked,
      queuedAt: nil,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T13:00:00Z",
      createdBy: "leader",
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil,
      awaitingReview: awaiting,
      reviewClaim: claim,
      consensus: consensus,
      reviewRound: 2,
      arbitration: arbitration,
      suggestedPersona: "code-reviewer",
      reviewHistory: [history]
    )

    let blob = encodedReviewMetadata(for: original)
    #expect(blob != nil)
    let row = CachedTaskReviewMetadata(
      sessionId: "sess-review",
      taskId: original.taskId,
      reviewBlob: try #require(blob)
    )
    container.mainContext.insert(row)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedTaskReviewMetadata>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let metadata = decodedReviewMetadata(from: fetched[0].reviewBlob)
    let cached = original.toCachedWorkItem()
    let restored = cached.toWorkItem(metadata: metadata)

    #expect(restored.awaitingReview == awaiting)
    #expect(restored.reviewClaim == claim)
    #expect(restored.consensus == consensus)
    #expect(restored.reviewRound == 2)
    #expect(restored.arbitration == arbitration)
    #expect(restored.suggestedPersona == "code-reviewer")
    #expect(restored.reviewHistory == [history])
  }

  @Test("Empty review state produces no cache row")
  func reviewMetadataEmptyProducesNoBlob() throws {
    let original = WorkItem(
      taskId: "task-plain",
      title: "Plain task",
      context: nil,
      severity: .medium,
      status: .open,
      assignedTo: nil,
      queuePolicy: .locked,
      queuedAt: nil,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T10:00:00Z",
      createdBy: nil,
      notes: [],
      suggestedFix: nil,
      source: .manual,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: nil
    )
    #expect(encodedReviewMetadata(for: original) == nil)
    let hydrated = original.toCachedWorkItem().toWorkItem()
    #expect(hydrated.awaitingReview == nil)
    #expect(hydrated.reviewHistory.isEmpty)
    #expect(hydrated.reviewRound == 0)
  }

  @Test("Review history array round-trips independent of consensus")
  func reviewHistoryRoundTripsStandalone() throws {
    let point = ReviewPoint(pointId: "p1", text: "nit", state: .disputed)
    let firstRound = ReviewConsensus(
      verdict: .requestChanges,
      summary: "round 1",
      points: [point],
      closedAt: "2026-03-28T11:00:00Z",
      reviewerAgentIds: ["rev-a"]
    )
    let secondRound = ReviewConsensus(
      verdict: .requestChanges,
      summary: "round 2",
      points: [point],
      closedAt: "2026-03-28T11:45:00Z",
      reviewerAgentIds: ["rev-b"]
    )
    let metadata = CachedReviewMetadata(
      awaitingReview: nil,
      reviewClaim: nil,
      consensus: nil,
      reviewRound: 3,
      arbitration: nil,
      suggestedPersona: nil,
      reviewHistory: [firstRound, secondRound]
    )
    let blob = try #require(try? Codecs.encoder.encode(metadata))
    let decoded = decodedReviewMetadata(from: blob)
    #expect(decoded.reviewHistory == [firstRound, secondRound])
    #expect(decoded.reviewRound == 3)
  }
}
