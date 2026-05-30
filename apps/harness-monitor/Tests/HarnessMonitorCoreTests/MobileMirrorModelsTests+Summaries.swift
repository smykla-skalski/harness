import Foundation
import HarnessMonitorCore
import XCTest

extension MobileMirrorModelsCommandTests {
  func testReviewSummaryBuildsPullRequestCommandPayload() throws {
    let review = MobileReviewSummary(
      id: "review-812",
      stationID: "station",
      repositoryID: "repo-1",
      repository: "smykla-skalski/harness",
      number: 812,
      url: "https://github.com/smykla-skalski/harness/pull/812",
      title: "Ship mobile reviews",
      author: "bart",
      state: "open",
      checksSummary: "success",
      headSha: "abc123",
      mergeable: "mergeable",
      reviewStatus: "review_required",
      checkStatus: "success",
      policyBlocked: true,
      isDraft: false,
      labels: ["mobile"],
      checks: [
        MobileReviewCheckSnippet(
          id: "check-1",
          name: "Tests",
          status: "completed",
          conclusion: "failure",
          checkSuiteID: "suite-1"
        )
      ],
      requiredFailedCheckNames: ["Tests"],
      viewerCanUpdate: false,
      viewerCanMergeAsAdmin: true,
      needsYou: true,
      updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let draft = review.commandDraft(
      kind: .pullRequestMerge,
      targetRevision: 42,
      mergeMethod: "squash",
      auditReason: "Checks and review are green."
    )
    let command = try draft.makeCommand(id: "command-merge", createdAt: review.updatedAt)

    XCTAssertEqual(command.target.reviewID, "review-812")
    XCTAssertEqual(command.target.targetRevision, 42)
    XCTAssertEqual(command.payload["repository"], "smykla-skalski/harness")
    XCTAssertEqual(command.payload["number"], "812")
    XCTAssertEqual(command.payload["headSha"], "abc123")
    XCTAssertEqual(command.payload["method"], "squash")
    XCTAssertEqual(command.payload["policyBlocked"], "true")
    XCTAssertEqual(command.payload["requiredFailedCheckNames"], "Tests")
    XCTAssertEqual(command.payload["checkSuiteIDs"], "suite-1")
    XCTAssertEqual(command.payload["viewerCanUpdate"], "false")
    XCTAssertEqual(command.payload["viewerCanMergeAsAdmin"], "true")
    XCTAssertEqual(command.auditReason, "Checks and review are green.")
  }

  func testReviewSummaryDecodesLegacyMirrorShape() throws {
    let payload = """
      {
        "id": "review-812",
        "stationID": "station",
        "repository": "smykla-skalski/harness",
        "number": 812,
        "title": "Ship mobile reviews",
        "author": "bart",
        "state": "open",
        "checksSummary": "success",
        "needsYou": true,
        "updatedAt": 1700000000
      }
      """

    let review = try JSONDecoder().decode(MobileReviewSummary.self, from: Data(payload.utf8))

    XCTAssertEqual(review.id, "review-812")
    XCTAssertEqual(review.repository, "smykla-skalski/harness")
    XCTAssertNil(review.headSha)
    XCTAssertNil(review.policyBlocked)
    XCTAssertEqual(review.labels, [])
    XCTAssertEqual(review.checks, [])
    XCTAssertEqual(review.files, [])
    XCTAssertEqual(review.activity, [])
    XCTAssertEqual(review.additions, 0)
    XCTAssertEqual(review.deletions, 0)
    XCTAssertEqual(review.requiredFailedCheckNames, [])
    XCTAssertTrue(review.viewerCanUpdate)
    XCTAssertFalse(review.viewerCanMergeAsAdmin)
    XCTAssertNil(review.filePaginationComplete)
  }

  func testTaskBoardSummaryBuildsCommandPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let item = MobileTaskBoardSummary(
      id: "task-16",
      stationID: "station",
      title: "Approve mobile sync plan",
      bodyPreview: "Review before implementation.",
      status: "plan_review",
      statusTitle: "Plan Review",
      priority: "high",
      priorityTitle: "High",
      tags: ["mobile"],
      projectID: "project",
      sessionID: "session-1",
      workItemID: "work-1",
      agentMode: "planning",
      needsYou: true,
      updatedAt: now
    )

    let draft = item.commandDraft(
      kind: .taskBoardDispatch,
      targetRevision: 42,
      status: "in_progress"
    )
    let command = try draft.makeCommand(id: "command-task", createdAt: now)

    XCTAssertEqual(command.target.taskID, "task-16")
    XCTAssertEqual(command.target.sessionID, "session-1")
    XCTAssertEqual(command.target.targetRevision, 42)
    XCTAssertEqual(command.payload["itemID"], "task-16")
    XCTAssertEqual(command.payload["status"], "in_progress")
    XCTAssertEqual(command.payload["priority"], "high")
    XCTAssertEqual(command.payload["projectID"], "project")
    XCTAssertEqual(command.payload["workItemID"], "work-1")
  }
}
