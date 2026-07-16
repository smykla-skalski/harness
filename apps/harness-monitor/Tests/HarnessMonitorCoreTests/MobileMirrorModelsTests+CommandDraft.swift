import Foundation
import HarnessMonitorCore
import XCTest

extension MobileMirrorModelsCommandTests {
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

  func testCommandDraftCanonicalizesLegacyStatusesAndRejectsUmbrella() throws {
    let target = MobileCommandTarget(
      stationID: "station",
      taskID: "task-1",
      targetRevision: 12
    )

    XCTAssertNoThrow(
      try MobileCommandDraft(
        kind: .taskBoardDispatch,
        confirmationText: "Dispatch task.",
        target: target,
        payload: ["status": "backlog"]
      ).validate()
    )
    for (legacyStatus, canonicalStatus) in [
      "new": "todo",
      "plan_review": "agentic_review",
      "needs_you": "human_required",
      "blocked": "failed",
    ] {
      let command = try MobileCommandDraft(
        kind: .taskBoardDispatch,
        confirmationText: "Dispatch task.",
        target: target,
        payload: ["status": legacyStatus]
      ).makeCommand(
        id: "command-\(legacyStatus)",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000)
      )
      XCTAssertEqual(command.payload["status"], canonicalStatus)
    }
    XCTAssertThrowsError(
      try MobileCommandDraft(
        kind: .taskBoardDispatch,
        confirmationText: "Dispatch task.",
        target: target,
        payload: ["status": "umbrella"]
      ).validate()
    ) { error in
      XCTAssertEqual(
        error as? MobileCommandDraftValidationError,
        .invalidPayload(key: "status", value: "umbrella")
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
}
