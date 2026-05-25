import Foundation
import HarnessMonitorCore
import XCTest

final class MobileMirrorModelsLiveActivityTests: XCTestCase {
  func testSnapshotDecodesLegacyMirrorWithoutTaskBoardItems() throws {
    let payload = """
      {
        "schemaVersion": 1,
        "revision": 12,
        "generatedAt": 1700000000,
        "expiresAt": 1700000600,
        "stations": [],
        "attention": [],
        "sessions": [],
        "reviews": [],
        "commands": []
      }
      """

    let snapshot = try JSONDecoder().decode(MobileMirrorSnapshot.self, from: Data(payload.utf8))

    XCTAssertEqual(snapshot.revision, 12)
    XCTAssertEqual(snapshot.taskBoardItems, [])
    XCTAssertEqual(snapshot.trustedDevices, [])
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

  func testSharedSnapshotStoreCanLoadExpiredLatestSnapshotForStaleDisplay() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fileURL = try temporarySnapshotFileURL()
    let store = MobileSharedSnapshotStore(fileURL: fileURL)
    var expired = MobileDemoFixtures.snapshot(now: now)
    expired.expiresAt = now.addingTimeInterval(-60)

    try store.save(expired, savedAt: now)

    XCTAssertNil(try store.loadSnapshot(now: now))
    XCTAssertEqual(try store.loadLatestSnapshot(), expired)
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
        mobileLiveActivityCommand(
          id: "queued",
          stationID: "station-a",
          status: .queued,
          risk: .destructive,
          updatedAt: now.addingTimeInterval(10)
        ),
        mobileLiveActivityCommand(
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
        mobileLiveActivityCommand(
          id: "station-a-running",
          stationID: "station-a",
          status: .running,
          updatedAt: now.addingTimeInterval(20)
        ),
        mobileLiveActivityCommand(
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
        mobileLiveActivityCommand(
          id: "succeeded",
          stationID: "station-a",
          status: .succeeded,
          updatedAt: now
        ),
        mobileLiveActivityCommand(
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

  func testPrimaryLiveActivityUsesCriticalDecisionWhenNoCommandIsRunning() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let criticalDecision = MobileAttentionItem(
      id: "permission",
      stationID: "station-a",
      kind: .acpDecision,
      severity: .critical,
      title: "Approve file access",
      subtitle: "Codex needs access to edit the plan.",
      updatedAt: now
    )
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
          needsYouCount: 1,
          commandQueueCount: 1
        )
      ],
      attention: [criticalDecision],
      sessions: [],
      reviews: [],
      commands: [
        liveActivityCommand(
          id: "queued",
          stationID: "station-a",
          status: .queued,
          risk: .destructive,
          updatedAt: now
        )
      ]
    )

    let presentation = MobileCommandLiveActivityPresentation.primaryActivity(
      in: snapshot,
      preferredStationID: "station-a",
      now: now
    )

    XCTAssertEqual(presentation?.commandID, "critical-decision-station-a-permission")
    XCTAssertEqual(presentation?.commandTitle, "Approve file access")
    XCTAssertEqual(presentation?.stationName, "Studio Mac")
    XCTAssertEqual(presentation?.status, "ACP Decision")
    XCTAssertEqual(presentation?.detail, "Codex needs access to edit the plan.")
    XCTAssertEqual(presentation?.systemImageName, "exclamationmark.octagon")
  }

  func testPrimaryLiveActivityKeepsRunningCommandAheadOfCriticalDecision() {
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
          needsYouCount: 1,
          commandQueueCount: 1
        )
      ],
      attention: [
        MobileAttentionItem(
          id: "permission",
          stationID: "station-a",
          kind: .acpDecision,
          severity: .critical,
          title: "Approve file access",
          subtitle: "Codex needs access.",
          updatedAt: now
        )
      ],
      sessions: [],
      reviews: [],
      commands: [
        liveActivityCommand(
          id: "running",
          stationID: "station-a",
          status: .running,
          updatedAt: now
        )
      ]
    )

    let presentation = MobileCommandLiveActivityPresentation.primaryActivity(
      in: snapshot,
      preferredStationID: "station-a",
      now: now
    )

    XCTAssertEqual(presentation?.commandID, "running")
    XCTAssertEqual(presentation?.systemImageName, "terminal")
  }

  private func temporarySnapshotFileURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("HarnessMonitorCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("latest-snapshot.json")
  }
}
