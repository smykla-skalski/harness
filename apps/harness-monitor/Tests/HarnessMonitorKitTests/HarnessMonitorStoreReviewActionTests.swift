import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store review actions")
struct HarnessMonitorStoreReviewActionTests {
  @Test("Review task actions send request and refresh the selected session")
  func reviewTaskActionsSendRequestsAndRefreshSession() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    let taskID = PreviewFixtures.tasks[0].taskId
    let reviewPoint = ReviewPoint(pointId: "point-1", text: "Tighten validation")

    await exerciseReviewTaskActions(store: store, taskID: taskID, reviewPoint: reviewPoint)

    #expect(client.recordedCalls() == expectedReviewCalls(taskID: taskID, point: reviewPoint))
    #expect(store.currentSuccessFeedbackMessage == "Apply improver patch")
  }

  private func exerciseReviewTaskActions(
    store: HarnessMonitorStore,
    taskID: String,
    reviewPoint: ReviewPoint
  ) async {
    await store.submitTaskForReview(
      taskID: taskID,
      summary: "Ready for review",
      suggestedPersona: "reviewer",
      actor: "leader-claude"
    )
    await store.claimTaskReview(taskID: taskID, actor: "reviewer-codex")
    await store.submitTaskReview(
      taskID: taskID,
      verdict: .requestChanges,
      summary: "Needs one fix",
      points: [reviewPoint],
      actor: "reviewer-codex"
    )
    await store.respondTaskReview(
      taskID: taskID,
      agreed: ["point-1"],
      disputed: [],
      note: "Fixed",
      actor: "worker-claude"
    )
    await store.arbitrateTask(
      taskID: taskID,
      verdict: .approve,
      summary: "Approved after response",
      actor: "leader-claude"
    )
    await store.applyImproverPatch(
      issueId: "issue-1",
      target: .skill,
      relPath: "skills/review/SKILL.md",
      newContents: "updated",
      projectDir: "/tmp/project",
      dryRun: true,
      actor: "leader-claude"
    )
  }

  private func expectedReviewCalls(
    taskID: String,
    point: ReviewPoint
  ) -> [RecordingHarnessClient.Call] {
    [
      .submitTaskForReview(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: taskID,
        actor: "leader-claude",
        summary: "Ready for review",
        suggestedPersona: "reviewer"
      ),
      .claimTaskReview(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: taskID,
        actor: "reviewer-codex"
      ),
      .submitTaskReview(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: taskID,
        actor: "reviewer-codex",
        verdict: .requestChanges,
        summary: "Needs one fix",
        points: [point]
      ),
      .respondTaskReview(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: taskID,
        actor: "worker-claude",
        agreed: ["point-1"],
        disputed: [],
        note: "Fixed"
      ),
      .arbitrateTask(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: taskID,
        actor: "leader-claude",
        verdict: .approve,
        summary: "Approved after response"
      ),
      .applyImproverPatch(
        sessionID: PreviewFixtures.summary.sessionId,
        actor: "leader-claude",
        issueID: "issue-1",
        target: .skill,
        relPath: "skills/review/SKILL.md",
        newContents: "updated",
        projectDir: "/tmp/project",
        dryRun: true
      ),
    ]
  }
}
