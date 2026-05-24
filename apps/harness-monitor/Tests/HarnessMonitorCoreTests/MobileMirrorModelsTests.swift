import Foundation
import HarnessMonitorCore
import XCTest

final class MobileMirrorModelsTests: XCTestCase {
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
