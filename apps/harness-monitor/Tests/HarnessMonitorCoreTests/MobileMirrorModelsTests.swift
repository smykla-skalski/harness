import Foundation
import HarnessMonitorCore
import XCTest

final class MobileMirrorModelsTests: XCTestCase {
  func testTrustedDeviceCollectionIDDisambiguatesSharedDeviceIDs() {
    let phone = MobileDeviceDescriptor(
      id: "default-mobile-device",
      displayName: "Bart's iPhone",
      publicKeyFingerprint: "AA:BB",
      pairedAt: .now
    )
    let watch = MobileDeviceDescriptor(
      id: "default-mobile-device",
      displayName: "Bart's Apple Watch",
      publicKeyFingerprint: "CC:DD",
      pairedAt: .now
    )

    XCTAssertEqual(phone.collectionID, "default-mobile-device|AA:BB")
    XCTAssertEqual(watch.collectionID, "default-mobile-device|CC:DD")
    XCTAssertNotEqual(phone.collectionID, watch.collectionID)
  }

  func testAttentionSortsCriticalItemsFirst() {
    let now = Date()
    let snapshot = MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [
        MobileAttentionItem(
          id: "warning",
          stationID: "station",
          kind: .pullRequest,
          severity: .warning,
          title: "Warning",
          subtitle: "",
          updatedAt: now
        ),
        MobileAttentionItem(
          id: "critical",
          stationID: "station",
          kind: .acpDecision,
          severity: .critical,
          title: "Critical",
          subtitle: "",
          updatedAt: now.addingTimeInterval(-60)
        ),
      ],
      sessions: [],
      reviews: [],
      commands: []
    )

    XCTAssertEqual(snapshot.sortedAttention.map(\.id), ["critical", "warning"])
  }

  func testNeedsYouCountIgnoresInformationalAttention() {
    let now = Date()
    let snapshot = MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [
        MobileAttentionItem(
          id: "task",
          stationID: "station",
          kind: .taskBoard,
          severity: .warning,
          title: "Plan review needed",
          subtitle: "",
          updatedAt: now
        ),
        MobileAttentionItem(
          id: "setup",
          stationID: "station",
          kind: .stationHealth,
          severity: .info,
          title: "Reviews are not configured",
          subtitle: "",
          updatedAt: now
        ),
      ],
      sessions: [],
      reviews: [],
      commands: []
    )

    XCTAssertEqual(snapshot.needsYouCount, 1)
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

  func testSessionSummaryDecodesLegacyMirrorShape() throws {
    let payload = """
      {
        "id": "session-1",
        "stationID": "station",
        "projectName": "Harness",
        "title": "Mobile relay",
        "branch": "main",
        "status": "Active",
        "activeAgentCount": 1,
        "blockedAgentCount": 0,
        "lastActivityAt": 1700000000,
        "summary": "Working"
      }
      """

    let session = try JSONDecoder().decode(MobileSessionSummary.self, from: Data(payload.utf8))

    XCTAssertEqual(session.id, "session-1")
    XCTAssertEqual(session.agents, [])
  }

  func testAgentSummaryBuildsPromptAndStopDrafts() throws {
    let agent = MobileAgentSummary(
      id: "agent-1",
      stationID: "station",
      sessionID: "session-1",
      displayName: "Codex",
      family: .codex,
      status: "Waiting Approval",
      isActive: true,
      isBlocked: true,
      pendingApprovalCount: 1,
      lastActivityAt: Date(timeIntervalSince1970: 1_700_000_000),
      summary: "Needs a prompt."
    )

    let promptDraft = agent.promptDraft(prompt: "Continue", targetRevision: 7)
    let stopDraft = agent.stopDraft(targetRevision: 7)

    XCTAssertEqual(promptDraft.kind, .agentPrompt)
    XCTAssertEqual(promptDraft.target.agentID, "agent-1")
    XCTAssertEqual(promptDraft.target.sessionID, "session-1")
    XCTAssertEqual(promptDraft.payload["prompt"], "Continue")
    XCTAssertEqual(stopDraft.kind, .agentStop)
    XCTAssertEqual(stopDraft.target.agentID, "agent-1")
  }

  func testSharedSnapshotStoreRoundTripsLatestSnapshot() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fileURL = try temporarySnapshotFileURL()
    let store = MobileSharedSnapshotStore(fileURL: fileURL)
    let snapshot = MobileDemoFixtures.snapshot(now: now)

    try store.save(snapshot, savedAt: now.addingTimeInterval(5))

    XCTAssertEqual(try store.loadArchive()?.savedAt, now.addingTimeInterval(5))
    XCTAssertEqual(try store.loadSnapshot(now: now), snapshot)
  }

  func testSharedSnapshotStoreIgnoresExpiredSnapshots() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fileURL = try temporarySnapshotFileURL()
    let store = MobileSharedSnapshotStore(fileURL: fileURL)
    let expired = MobileMirrorSnapshot.empty(now: now.addingTimeInterval(-60))

    try store.save(expired, savedAt: now)

    XCTAssertNil(try store.loadSnapshot(now: now))
  }

  func testLiveActivityPresentationSelectsRunningCommandFirst() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileMirrorSnapshot(
      revision: 3,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [
        MobileStationSummary(
          id: "station-a",
          displayName: "Studio Mac",
          state: .online,
          lastSeenAt: now,
          activeSessionCount: 1,
          needsYouCount: 0,
          commandQueueCount: 2
        )
      ],
      attention: [],
      sessions: [],
      reviews: [],
      commands: [
        liveActivityCommand(
          id: "queued",
          stationID: "station-a",
          status: .queued,
          risk: .destructive,
          updatedAt: now.addingTimeInterval(10)
        ),
        liveActivityCommand(
          id: "running",
          stationID: "station-a",
          status: .running,
          risk: .low,
          updatedAt: now
        ),
      ]
    )

    let presentation = MobileCommandLiveActivityPresentation.activeCommand(
      in: snapshot,
      preferredStationID: "station-a",
      now: now
    )

    XCTAssertEqual(presentation?.commandID, "running")
    XCTAssertEqual(presentation?.stationName, "Studio Mac")
    XCTAssertEqual(presentation?.status, "Running")
    XCTAssertEqual(presentation?.detail, "Executing revision 3")
  }

  func testLiveActivityPresentationPrefersSelectedStationWhenItHasActiveCommand() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileMirrorSnapshot(
      revision: 3,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [
        MobileStationSummary(
          id: "station-a",
          displayName: "Studio Mac",
          state: .online,
          lastSeenAt: now,
          activeSessionCount: 1,
          needsYouCount: 0,
          commandQueueCount: 1
        ),
        MobileStationSummary(
          id: "station-b",
          displayName: "Laptop",
          state: .online,
          lastSeenAt: now,
          activeSessionCount: 1,
          needsYouCount: 0,
          commandQueueCount: 1
        ),
      ],
      attention: [],
      sessions: [],
      reviews: [],
      commands: [
        liveActivityCommand(
          id: "station-a-running",
          stationID: "station-a",
          status: .running,
          updatedAt: now.addingTimeInterval(20)
        ),
        liveActivityCommand(
          id: "station-b-queued",
          stationID: "station-b",
          status: .queued,
          updatedAt: now
        ),
      ]
    )

    let presentation = MobileCommandLiveActivityPresentation.activeCommand(
      in: snapshot,
      preferredStationID: "station-b",
      now: now
    )

    XCTAssertEqual(presentation?.commandID, "station-b-queued")
    XCTAssertEqual(presentation?.stationName, "Laptop")
  }

  func testLiveActivityPresentationIgnoresTerminalAndExpiredCommands() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileMirrorSnapshot(
      revision: 3,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [],
      sessions: [],
      reviews: [],
      commands: [
        liveActivityCommand(
          id: "succeeded",
          stationID: "station-a",
          status: .succeeded,
          updatedAt: now
        ),
        liveActivityCommand(
          id: "expired",
          stationID: "station-a",
          status: .queued,
          updatedAt: now,
          expiresAt: now.addingTimeInterval(-1)
        ),
      ]
    )

    XCTAssertNil(
      MobileCommandLiveActivityPresentation.activeCommand(
        in: snapshot,
        preferredStationID: "station-a",
        now: now
      )
    )
  }

  private func temporarySnapshotFileURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("latest-snapshot.json")
  }

  private func liveActivityCommand(
    id: String,
    stationID: String,
    status: MobileCommandStatus,
    risk: MobileCommandRisk = .low,
    updatedAt: Date,
    expiresAt: Date? = nil
  ) -> MobileCommandRecord {
    MobileCommandRecord(
      id: id,
      stationID: stationID,
      kind: .refresh,
      risk: risk,
      status: status,
      title: "Refresh",
      confirmationText: "Refresh station.",
      target: MobileCommandTarget(stationID: stationID, targetRevision: 3),
      actorDeviceID: "phone",
      createdAt: updatedAt.addingTimeInterval(-30),
      expiresAt: expiresAt ?? updatedAt.addingTimeInterval(15 * 60),
      updatedAt: updatedAt
    )
  }
}
