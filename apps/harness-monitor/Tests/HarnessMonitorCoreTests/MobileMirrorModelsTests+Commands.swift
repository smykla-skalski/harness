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

  func testQueueValidationRejectsMalformedCommandIdentityAndCopy() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let emptyCommandID = mobileCommand(" ", stationID: "station", now: now)
    assertQueueValidation(
      emptyCommandID,
      now: now,
      throws: .emptyCommandID
    )

    var emptyStationID = mobileCommand("command", stationID: " ", now: now)
    emptyStationID.target.stationID = " "
    assertQueueValidation(
      emptyStationID,
      now: now,
      throws: .emptyStationID
    )

    var mismatchedTargetStation = mobileCommand("command", stationID: "station", now: now)
    mismatchedTargetStation.target.stationID = "other-station"
    assertQueueValidation(
      mismatchedTargetStation,
      now: now,
      throws: .targetStationMismatch(expected: "station", actual: "other-station")
    )

    var missingTitle = mobileCommand("command", stationID: "station", now: now)
    missingTitle.title = " "
    assertQueueValidation(
      missingTitle,
      now: now,
      throws: .missingTitle
    )

    var missingConfirmation = mobileCommand("command", stationID: "station", now: now)
    missingConfirmation.confirmationText = " "
    assertQueueValidation(
      missingConfirmation,
      now: now,
      throws: .missingConfirmationText
    )
  }

  func testQueueValidationRejectsInvalidLifetimeBeforeExpiryChecks() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var command = mobileCommand("command", stationID: "station", now: now)
    command.createdAt = now.addingTimeInterval(120)
    command.expiresAt = now.addingTimeInterval(60)

    assertQueueValidation(
      command,
      now: now,
      throws: .invalidLifetime(
        createdAt: now.addingTimeInterval(120),
        expiresAt: now.addingTimeInterval(60)
      )
    )
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

  private func assertQueueValidation(
    _ command: MobileCommandRecord,
    now: Date,
    throws expectedError: MobileCommandValidationError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(try command.validatingForQueue(now: now), file: file, line: line) { error in
      XCTAssertEqual(error as? MobileCommandValidationError, expectedError, file: file, line: line)
    }
  }
}
