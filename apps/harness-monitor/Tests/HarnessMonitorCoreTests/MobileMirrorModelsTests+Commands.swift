import Foundation
import HarnessMonitorCore
import XCTest

final class MobileMirrorModelsCommandTests: XCTestCase {
  func testKeepingStationDataDropsStaleUnpairedStations() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileMirrorSnapshot(
      revision: 4,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [
        mobileStation("station-a", name: "Studio", defaultStation: true, now: now),
        mobileStation("station-b", name: "Laptop", defaultStation: false, now: now),
      ],
      attention: [
        mobileAttention("attention-a", stationID: "station-a", now: now),
        mobileAttention("attention-b", stationID: "station-b", now: now),
      ],
      sessions: [
        mobileSession("session-a", stationID: "station-a", now: now),
        mobileSession("session-b", stationID: "station-b", now: now),
      ],
      reviews: [
        mobileReview("review-a", stationID: "station-a", now: now),
        mobileReview("review-b", stationID: "station-b", now: now),
      ],
      taskBoardItems: [
        mobileTaskBoardItem("task-a", stationID: "station-a", now: now),
        mobileTaskBoardItem("task-b", stationID: "station-b", now: now),
      ],
      commands: [
        mobileCommand("command-a", stationID: "station-a", now: now),
        mobileCommand("command-b", stationID: "station-b", now: now),
      ]
    )

    let scoped = snapshot.keepingStationData(
      for: [" station-b ", "station-b"],
      defaultStationID: "station-b"
    )

    XCTAssertEqual(scoped.revision, snapshot.revision)
    XCTAssertEqual(scoped.stations.map(\.id), ["station-b"])
    XCTAssertEqual(scoped.station(id: "station-b")?.defaultStation, true)
    XCTAssertEqual(scoped.attention.map(\.id), ["attention-b"])
    XCTAssertEqual(scoped.sessions.map(\.id), ["session-b"])
    XCTAssertEqual(scoped.reviews.map(\.id), ["review-b"])
    XCTAssertEqual(scoped.taskBoardItems.map(\.id), ["task-b"])
    XCTAssertEqual(scoped.commands.map(\.id), ["command-b"])
  }

  func testAttentionCarriesEncryptedCommandPayload() {
    let item = MobileAttentionItem(
      id: "permission",
      stationID: "station",
      kind: .acpDecision,
      severity: .critical,
      title: "Permission requested",
      subtitle: "Agent wants access.",
      updatedAt: .now,
      commandKind: .acpPermissionDecision,
      target: MobileCommandTarget(
        stationID: "station",
        agentID: "agent",
        targetRevision: 7
      ),
      commandPayload: ["batchID": "batch-1", "decision": "approve_all"]
    )

    XCTAssertEqual(item.commandPayload["batchID"], "batch-1")
    XCTAssertEqual(item.commandPayload["decision"], "approve_all")
  }

  func testDestructiveCommandRequiresAuditReason() {
    let command = MobileCommandRecord(
      id: "command",
      stationID: "station",
      kind: .pullRequestMerge,
      risk: .destructive,
      status: .queued,
      title: "Merge",
      confirmationText: "Merge PR",
      target: MobileCommandTarget(stationID: "station", targetRevision: 4),
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(60),
      updatedAt: .now
    )

    XCTAssertThrowsError(try command.validatingForQueue(now: .now)) { error in
      XCTAssertEqual(error as? MobileCommandValidationError, .destructiveCommandMissingAuditReason)
    }
  }

  func testHighRiskCommandRejectsStaleRevision() {
    let command = MobileCommandRecord(
      id: "command",
      stationID: "station",
      kind: .taskBoardPlanApproval,
      risk: .high,
      status: .queued,
      title: "Approve",
      confirmationText: "Approve plan",
      auditReason: "Plan reviewed.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 4),
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(60),
      updatedAt: .now
    )

    XCTAssertThrowsError(try command.validatingFreshState(currentRevision: 5)) { error in
      XCTAssertEqual(
        error as? MobileCommandValidationError,
        .staleRevision(expected: 4, actual: 5)
      )
    }
  }

  func testRetryDraftPreservesCommandAndUsesCurrentRevision() throws {
    let original = MobileCommandRecord(
      id: "command-old",
      stationID: "station",
      kind: .pullRequestMerge,
      risk: .destructive,
      status: .failed,
      title: "Merge",
      confirmationText: "Merge PR #812.",
      auditReason: "Reviewed on phone.",
      target: MobileCommandTarget(
        stationID: "station",
        reviewID: "review-812",
        targetRevision: 4
      ),
      payload: ["method": "squash"],
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(-60),
      updatedAt: .now
    )

    let draft = try original.retryDraft(currentRevision: 9, expiresAfter: 600)
    let retried = try draft.makeCommand(
      id: "command-retry",
      actorDeviceID: "phone",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(retried.id, "command-retry")
    XCTAssertEqual(retried.kind, original.kind)
    XCTAssertEqual(retried.title, original.title)
    XCTAssertEqual(retried.confirmationText, original.confirmationText)
    XCTAssertEqual(retried.auditReason, original.auditReason)
    XCTAssertEqual(retried.target.reviewID, "review-812")
    XCTAssertEqual(retried.target.targetRevision, 9)
    XCTAssertEqual(retried.payload, original.payload)
    XCTAssertEqual(retried.status, .draft)
  }

  func testRetryDraftRejectsNonTerminalCommand() {
    let command = MobileCommandRecord(
      id: "command-running",
      stationID: "station",
      kind: .refresh,
      risk: .low,
      status: .running,
      title: "Refresh",
      confirmationText: "Refresh.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 4),
      actorDeviceID: "phone",
      createdAt: .now,
      expiresAt: Date().addingTimeInterval(60),
      updatedAt: .now
    )

    XCTAssertThrowsError(try command.retryDraft(currentRevision: 5)) { error in
      XCTAssertEqual(error as? MobileCommandRetryError, .notRetryable(status: .running))
    }
  }

  func testCommandDraftBuildsRefreshCommand() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = MobileCommandDraft(
      kind: .refresh,
      confirmationText: "Refresh station health.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 12),
      payload: ["scope": "health"]
    )

    let command = try draft.makeCommand(id: "command-refresh", createdAt: now)

    XCTAssertEqual(command.kind, .refresh)
    XCTAssertEqual(command.risk, .low)
    XCTAssertEqual(command.status, .draft)
    XCTAssertEqual(command.payload["scope"], "health")
    XCTAssertEqual(command.expiresAt, now.addingTimeInterval(15 * 60))
  }

  func testCommandDraftNormalizesTargetAndPayloadKeys() throws {
    let draft = MobileCommandDraft(
      kind: .agentPrompt,
      title: " Prompt agent ",
      confirmationText: " Send prompt ",
      target: MobileCommandTarget(
        stationID: " station ",
        agentID: " agent-1 ",
        targetRevision: 12
      ),
      payload: [" prompt ": " Continue implementation ", "empty": "  "]
    )

    let command = try draft.makeCommand(
      id: "command-prompt",
      actorDeviceID: "phone",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(command.stationID, "station")
    XCTAssertEqual(command.target.stationID, "station")
    XCTAssertEqual(command.target.agentID, "agent-1")
    XCTAssertEqual(command.title, "Prompt agent")
    XCTAssertEqual(command.confirmationText, "Send prompt")
    XCTAssertEqual(command.payload, ["prompt": "Continue implementation"])
  }

  func testCommandDraftRejectsNonPositiveExpiry() {
    let draft = MobileCommandDraft(
      kind: .refresh,
      confirmationText: "Refresh station health.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 12),
      payload: ["scope": "health"],
      expiresAfter: 0
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "expiresAfter", value: "0.0")
      )
    }
  }

  func testCommandDraftRejectsPartialAcpApprovalWithoutRequestIDs() {
    let draft = MobileCommandDraft(
      kind: .acpPermissionDecision,
      confirmationText: "Approve selected requests.",
      target: MobileCommandTarget(
        stationID: "station",
        agentID: "agent-1",
        targetRevision: 12
      ),
      payload: ["batchID": "batch-1", "decision": "approve_some"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .missingPayload("request IDs")
      )
    }
  }

  func testCommandDraftRejectsInvalidPullRequestNumber() {
    let draft = MobileCommandDraft(
      kind: .pullRequestApprove,
      confirmationText: "Approve PR.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 12),
      payload: ["repository": "smykla-skalski/harness", "number": "zero"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "number", value: "zero")
      )
    }
  }

  func testCommandDraftRejectsTaskDispatchWithoutItemTarget() {
    let draft = MobileCommandDraft(
      kind: .taskBoardDispatch,
      confirmationText: "Move task.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 12),
      payload: ["status": "todo"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .missingTarget("task ID")
      )
    }
  }

  func testCommandDraftRejectsInvalidTaskDispatchBoolean() {
    let draft = MobileCommandDraft(
      kind: .taskBoardDispatch,
      confirmationText: "Move task.",
      target: MobileCommandTarget(
        stationID: "station",
        taskID: "task-1",
        targetRevision: 12
      ),
      payload: ["status": "todo", "dryRun": "sometimes"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "dryRun", value: "sometimes")
      )
    }
  }

  func testCommandDraftRejectsInvalidAgentStartPayloads() {
    let target = MobileCommandTarget(
      stationID: "station",
      sessionID: "session-1",
      targetRevision: 12
    )

    XCTAssertThrowsError(
      try MobileCommandDraft(
        kind: .agentStart,
        confirmationText: "Start agent.",
        target: target,
        payload: ["agent": "codex", "allowCustomModel": "maybe"]
      ).validate()
    ) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "allowCustomModel", value: "maybe")
      )
    }

    XCTAssertThrowsError(
      try MobileCommandDraft(
        kind: .agentStart,
        confirmationText: "Start agent.",
        target: target,
        payload: ["agent": "codex", "rows": "0"]
      ).validate()
    ) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "rows", value: "0")
      )
    }

    XCTAssertThrowsError(
      try MobileCommandDraft(
        kind: .agentStart,
        confirmationText: "Start agent.",
        target: target,
        payload: ["agent": "codex", "role": "captain"]
      ).validate()
    ) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "role", value: "captain")
      )
    }
  }

  func testCommandDraftRejectsInvalidMergeMethod() {
    let draft = MobileCommandDraft(
      kind: .pullRequestMerge,
      confirmationText: "Merge PR.",
      auditReason: "Reviewed on phone.",
      target: MobileCommandTarget(
        stationID: "station",
        reviewID: "review-812",
        targetRevision: 12
      ),
      payload: ["method": "shipit"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "method", value: "shipit")
      )
    }
  }

  func testCommandDraftAcceptsMirrorGeneratedRefreshScopes() throws {
    let stationTarget = MobileCommandTarget(stationID: "station", targetRevision: 12)
    let sessionTarget = MobileCommandTarget(
      stationID: "station",
      sessionID: "session-1",
      taskID: "task-1",
      targetRevision: 12
    )

    XCTAssertNoThrow(
      try MobileCommandDraft(
        kind: .refresh,
        confirmationText: "Refresh mobile mirror.",
        target: stationTarget,
        payload: ["scope": "mobileMirror"]
      ).validate()
    )
    XCTAssertNoThrow(
      try MobileCommandDraft(
        kind: .refresh,
        confirmationText: "Refresh Reviews.",
        target: stationTarget,
        payload: ["scope": "reviews"]
      ).validate()
    )
    XCTAssertNoThrow(
      try MobileCommandDraft(
        kind: .refresh,
        confirmationText: "Refresh session tasks.",
        target: sessionTarget,
        payload: ["scope": "sessionTasks"]
      ).validate()
    )
  }

  func testCommandDraftRequiresSessionForSessionTaskRefresh() {
    let draft = MobileCommandDraft(
      kind: .refresh,
      confirmationText: "Refresh session tasks.",
      target: MobileCommandTarget(stationID: "station", targetRevision: 12),
      payload: ["scope": "sessionTasks"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(error as? MobileCommandDraftValidationError, .missingTarget("session ID"))
    }
  }

  func testCommandDraftRequiresMergeAuditReason() {
    let draft = MobileCommandDraft(
      kind: .pullRequestMerge,
      confirmationText: "Merge PR #812.",
      target: MobileCommandTarget(
        stationID: "station",
        reviewID: "review-812",
        targetRevision: 12
      ),
      payload: ["method": "squash"]
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(error as? MobileCommandDraftValidationError, .missingAuditReason)
    }
  }

  func testCommandDraftRequiresAgentPromptPayload() {
    let draft = MobileCommandDraft(
      kind: .agentPrompt,
      confirmationText: "Prompt agent.",
      target: MobileCommandTarget(
        stationID: "station",
        agentID: "agent-codex",
        targetRevision: 12
      )
    )

    XCTAssertThrowsError(try draft.validate()) { error in
      XCTAssertEqual(error as? MobileCommandDraftValidationError, .missingPayload("prompt"))
    }
  }

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
