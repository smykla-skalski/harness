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

  func testCrossStationMergeKeepsDevicesSharingDefaultIdentityID() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let base = MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [mobileStation("station-a", name: "Studio", defaultStation: true, now: now)],
      attention: [],
      sessions: [],
      reviews: [],
      commands: [],
      trustedDevices: [
        MobileDeviceDescriptor(
          id: "default-mobile-device",
          displayName: "iPhone",
          publicKeyFingerprint: "AA:BB",
          pairedAt: now
        )
      ]
    )
    let refreshed = MobileMirrorSnapshot(
      revision: 2,
      generatedAt: now.addingTimeInterval(30),
      expiresAt: now.addingTimeInterval(300),
      stations: [mobileStation("station-a", name: "Studio", defaultStation: true, now: now)],
      attention: [],
      sessions: [],
      reviews: [],
      commands: [],
      trustedDevices: [
        MobileDeviceDescriptor(
          id: "default-mobile-device",
          displayName: "Apple Watch",
          publicKeyFingerprint: "CC:DD",
          pairedAt: now
        )
      ]
    )

    let merged = base.mergingStationSnapshot(
      refreshed,
      stationID: "station-a",
      defaultStationID: "station-a"
    )

    // Both devices use the default identity id, so the merge must keep both
    // (deduping by id would drop one) and keying a list on `id` collides - the
    // SwiftUI "occurs multiple times" fault. collectionID stays unique, which is
    // what the trusted-device lists key on.
    XCTAssertEqual(merged.trustedDevices.count, 2)
    XCTAssertEqual(Set(merged.trustedDevices.map { $0.id }).count, 1)
    XCTAssertEqual(Set(merged.trustedDevices.map { $0.collectionID }).count, 2)
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

  func testNeedsYouCockpitDerivesReviewsTasksAgentsCommandsAndStations() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var staleStation = mobileStation("station-stale", name: "Studio", defaultStation: false, now: now)
    staleStation.state = .stale
    staleStation.lastSeenAt = now.addingTimeInterval(-300)
    var failedCommand = mobileCommand("command-failed", stationID: "station", now: now)
    failedCommand.status = .failed
    failedCommand.updatedAt = now.addingTimeInterval(4)
    failedCommand.receipt = MobileCommandReceipt(
      commandID: failedCommand.id,
      stationID: failedCommand.stationID,
      status: .failed,
      message: "Mac relay rejected the command.",
      receivedAt: now.addingTimeInterval(3),
      completedAt: now.addingTimeInterval(4),
      executionRevision: 10
    )
    let blockedAgent = MobileAgentSummary(
      id: "agent-blocked",
      stationID: "station",
      sessionID: "session-blocked",
      displayName: "Codex",
      family: .codex,
      status: "Waiting",
      isActive: true,
      isBlocked: true,
      pendingPermissionCount: 1,
      lastActivityAt: now.addingTimeInterval(3),
      summary: "Permission needed"
    )
    var blockedSession = mobileSession("session-blocked", stationID: "station", now: now)
    blockedSession.blockedAgentCount = 1
    blockedSession.agents = [blockedAgent]
    let snapshot = MobileMirrorSnapshot(
      revision: 10,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [mobileStation("station", name: "Mac", defaultStation: true, now: now), staleStation],
      attention: [],
      sessions: [blockedSession],
      reviews: [mobileReview("review-needs-you", stationID: "station", now: now)],
      taskBoardItems: [mobileTaskBoardItem("task-plan", stationID: "station", now: now)],
      commands: [failedCommand]
    )

    let attentionByKind = Dictionary(grouping: snapshot.sortedAttention, by: \.kind)

    XCTAssertEqual(snapshot.needsYouCount, 6)
    XCTAssertEqual(attentionByKind[.pullRequest]?.map(\.id), ["derived-review-review-needs-you"])
    XCTAssertEqual(attentionByKind[.taskBoard]?.map(\.id), ["derived-task-task-plan"])
    XCTAssertEqual(attentionByKind[.commandFailure]?.map(\.id), ["derived-command-command-failed"])
    XCTAssertEqual(attentionByKind[.stationHealth]?.map(\.id), [
      "derived-station-station-stale-stale"
    ])
    XCTAssertEqual(Set(attentionByKind[.blockedAgent]?.map(\.id) ?? []), [
      "derived-agent-agent-blocked",
      "derived-session-session-blocked",
    ])
  }

  func testSynthesizedAttentionCopyHasNoTrailingPeriodAndPluralizes() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let offlineStation = MobileStationSummary(
      id: "station",
      displayName: "Mac",
      state: .offline,
      lastSeenAt: now.addingTimeInterval(-3600),
      activeSessionCount: 0,
      needsYouCount: 0,
      commandQueueCount: 0,
      defaultStation: true
    )
    let blockedAgent = MobileAgentSummary(
      id: "agent-blocked",
      stationID: "station",
      sessionID: "session-blocked",
      displayName: "Codex",
      family: .codex,
      status: "Waiting",
      isActive: true,
      isBlocked: true,
      pendingPermissionCount: 1,
      lastActivityAt: now,
      summary: "Permission needed"
    )
    var blockedSession = mobileSession("session-blocked", stationID: "station", now: now)
    blockedSession.blockedAgentCount = 2
    blockedSession.agents = [blockedAgent]
    let snapshot = MobileMirrorSnapshot(
      revision: 10,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [offlineStation],
      attention: [],
      sessions: [blockedSession],
      reviews: [],
      commands: []
    )

    for item in snapshot.sortedAttention {
      XCTAssertFalse(
        item.title.hasSuffix(".") && !item.title.hasSuffix(".."),
        "attention title ends with a lone period: \(item.title)")
      XCTAssertFalse(
        item.subtitle.hasSuffix(".") && !item.subtitle.hasSuffix(".."),
        "attention subtitle ends with a lone period: \(item.subtitle)")
    }

    let sessionItem = snapshot.sortedAttention.first { $0.id == "derived-session-session-blocked" }
    XCTAssertEqual(sessionItem?.title, "2 agents waiting")
  }

  func testDerivedReviewAttentionCanQueueApproveCommandWithReviewPayload() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileMirrorSnapshot(
      revision: 11,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [mobileStation("station", name: "Mac", defaultStation: true, now: now)],
      attention: [],
      sessions: [],
      reviews: [mobileReview("review-812", stationID: "station", now: now)],
      commands: []
    )

    let item = try XCTUnwrap(snapshot.sortedAttention.first)

    XCTAssertEqual(item.kind, .pullRequest)
    XCTAssertEqual(item.commandKind, .pullRequestApprove)
    XCTAssertEqual(item.target?.reviewID, "review-812")
    XCTAssertEqual(item.target?.targetRevision, 11)
    XCTAssertEqual(item.commandPayload["pullRequestID"], "review-812")
    XCTAssertEqual(item.commandPayload["repository"], "harness")
  }

  func testDerivedTaskBoardAttentionCarriesPlanApprovalCommandTarget() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var task = mobileTaskBoardItem("task-plan", stationID: "station", now: now)
    task.status = "plan_review"
    task.statusTitle = "Plan Review"
    let snapshot = MobileMirrorSnapshot(
      revision: 12,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [mobileStation("station", name: "Mac", defaultStation: true, now: now)],
      attention: [],
      sessions: [],
      reviews: [],
      taskBoardItems: [task],
      commands: []
    )

    let item = try XCTUnwrap(snapshot.sortedAttention.first)

    XCTAssertEqual(item.kind, .taskBoard)
    XCTAssertEqual(item.commandKind, .taskBoardPlanApproval)
    XCTAssertEqual(item.target?.taskID, "task-plan")
    XCTAssertEqual(item.target?.targetRevision, 12)
    XCTAssertEqual(item.commandPayload["itemID"], "task-plan")
  }

  func testRawAttentionSuppressesDerivedDuplicatesForSameEntities() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var staleStation = mobileStation("station", name: "Mac", defaultStation: true, now: now)
    staleStation.state = .offline
    let rawReview = MobileAttentionItem(
      id: "raw-review",
      stationID: "station",
      kind: .pullRequest,
      severity: .critical,
      title: "Raw review",
      subtitle: "",
      updatedAt: now,
      target: MobileCommandTarget(stationID: "station", reviewID: "review-812", targetRevision: 1)
    )
    let rawTask = MobileAttentionItem(
      id: "raw-task",
      stationID: "station",
      kind: .taskBoard,
      severity: .warning,
      title: "Raw task",
      subtitle: "",
      updatedAt: now,
      target: MobileCommandTarget(stationID: "station", taskID: "task-1", targetRevision: 1)
    )
    let rawStation = MobileAttentionItem(
      id: "raw-station",
      stationID: "station",
      kind: .stationHealth,
      severity: .critical,
      title: "Raw station",
      subtitle: "",
      updatedAt: now
    )
    let snapshot = MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [staleStation],
      attention: [rawReview, rawTask, rawStation],
      sessions: [],
      reviews: [mobileReview("review-812", stationID: "station", now: now)],
      taskBoardItems: [mobileTaskBoardItem("task-1", stationID: "station", now: now)],
      commands: []
    )

    XCTAssertEqual(snapshot.sortedAttention.map(\.id).sorted(), [
      "raw-review",
      "raw-station",
      "raw-task",
    ])
  }

  func testStationSnapshotMergeRefreshesOneStationWithoutDroppingOthers() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let base = MobileMirrorSnapshot(
      revision: 4,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [
        mobileStation("station-a", name: "Old Studio", defaultStation: true, now: now),
        mobileStation("station-b", name: "Laptop", defaultStation: false, now: now),
      ],
      attention: [
        mobileAttention("attention-a-old", stationID: "station-a", now: now),
        mobileAttention("attention-b", stationID: "station-b", now: now),
      ],
      sessions: [
        mobileSession("session-a-old", stationID: "station-a", now: now),
        mobileSession("session-b", stationID: "station-b", now: now),
      ],
      reviews: [
        mobileReview("review-a-old", stationID: "station-a", now: now),
        mobileReview("review-b", stationID: "station-b", now: now),
      ],
      taskBoardItems: [
        mobileTaskBoardItem("task-a-old", stationID: "station-a", now: now),
        mobileTaskBoardItem("task-b", stationID: "station-b", now: now),
      ],
      commands: [
        mobileCommand("command-a-old", stationID: "station-a", now: now),
        mobileCommand("command-b", stationID: "station-b", now: now),
      ],
      trustedDevices: [
        MobileDeviceDescriptor(
          id: "phone",
          displayName: "Phone",
          publicKeyFingerprint: "AA:BB",
          pairedAt: now
        ),
        MobileDeviceDescriptor(
          id: "watch",
          displayName: "Watch",
          publicKeyFingerprint: "CC:DD",
          pairedAt: now
        ),
      ]
    )
    let refreshed = MobileMirrorSnapshot(
      revision: 7,
      generatedAt: now.addingTimeInterval(30),
      expiresAt: now.addingTimeInterval(300),
      stations: [
        mobileStation("station-a", name: "Studio", defaultStation: false, now: now)
      ],
      attention: [
        mobileAttention("attention-a-new", stationID: "station-a", now: now)
      ],
      sessions: [
        mobileSession("session-a-new", stationID: "station-a", now: now)
      ],
      reviews: [
        mobileReview("review-a-new", stationID: "station-a", now: now)
      ],
      taskBoardItems: [
        mobileTaskBoardItem("task-a-new", stationID: "station-a", now: now)
      ],
      commands: [
        mobileCommand("command-a-new", stationID: "station-a", now: now)
      ],
      trustedDevices: [
        MobileDeviceDescriptor(
          id: "phone",
          displayName: "Phone refreshed",
          publicKeyFingerprint: "AA:BB",
          pairedAt: now
        ),
      ]
    )

    let merged = base.mergingStationSnapshot(
      refreshed,
      stationID: "station-a",
      defaultStationID: "station-b"
    )

    XCTAssertEqual(merged.revision, 7)
    XCTAssertEqual(merged.generatedAt, now.addingTimeInterval(30))
    XCTAssertEqual(merged.expiresAt, now.addingTimeInterval(300))
    XCTAssertEqual(merged.stations.map(\.id), ["station-b", "station-a"])
    XCTAssertEqual(merged.station(id: "station-a")?.displayName, "Studio")
    XCTAssertEqual(merged.station(id: "station-b")?.displayName, "Laptop")
    XCTAssertEqual(merged.station(id: "station-a")?.defaultStation, false)
    XCTAssertEqual(merged.station(id: "station-b")?.defaultStation, true)
    XCTAssertEqual(merged.attention.map(\.id).sorted(), ["attention-a-new", "attention-b"])
    XCTAssertEqual(merged.sessions.map(\.id).sorted(), ["session-a-new", "session-b"])
    XCTAssertEqual(merged.reviews.map(\.id).sorted(), ["review-a-new", "review-b"])
    XCTAssertEqual(merged.taskBoardItems.map(\.id).sorted(), ["task-a-new", "task-b"])
    XCTAssertEqual(merged.commands.map(\.id).sorted(), ["command-a-new", "command-b"])
    XCTAssertEqual(
      merged.trustedDevices.first { $0.id == "phone" }?.displayName,
      "Phone refreshed"
    )
    XCTAssertEqual(merged.trustedDevices.first { $0.id == "watch" }?.displayName, "Watch")
  }

  func testRemovingStationDataPreservesOtherStations() {
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

    let pruned = snapshot.removingStationData(
      for: [" station-a ", "station-a"],
      defaultStationID: "station-b"
    )

    XCTAssertEqual(pruned.stations.map(\.id), ["station-b"])
    XCTAssertEqual(pruned.station(id: "station-b")?.defaultStation, true)
    XCTAssertEqual(pruned.attention.map(\.id), ["attention-b"])
    XCTAssertEqual(pruned.sessions.map(\.id), ["session-b"])
    XCTAssertEqual(pruned.reviews.map(\.id), ["review-b"])
    XCTAssertEqual(pruned.taskBoardItems.map(\.id), ["task-b"])
    XCTAssertEqual(pruned.commands.map(\.id), ["command-b"])
  }
}
