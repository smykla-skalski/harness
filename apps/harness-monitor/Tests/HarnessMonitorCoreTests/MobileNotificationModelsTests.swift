import Foundation
import HarnessMonitorCore
import XCTest

final class MobileNotificationModelsTests: XCTestCase {
  func testNotificationSettingsPersistDisabledCategory() throws {
    let suiteName = "MobileNotificationModelsTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }

    var settings = MobileNotificationSettings.smartDefaults
    settings.setEnabled(false, for: .commandStatus)
    settings.save(to: defaults)

    let reloaded = MobileNotificationSettings.load(from: defaults)

    XCTAssertFalse(reloaded.isEnabled(.commandStatus))
    XCTAssertTrue(reloaded.isEnabled(.needsYou))
    XCTAssertTrue(reloaded.isEnabled(.commandFailure))
  }

  func testPlannerEmitsSmartNotificationsForNewSnapshotEvents() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let previous = MobileMirrorSnapshot.empty(now: now.addingTimeInterval(-60))
    let next = MobileMirrorSnapshot(
      revision: 4,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [
        MobileStationSummary(
          id: "station",
          displayName: "Mac Studio",
          state: .stale,
          lastSeenAt: now.addingTimeInterval(-600),
          activeSessionCount: 2,
          needsYouCount: 1,
          commandQueueCount: 1
        )
      ],
      attention: [
        MobileAttentionItem(
          id: "attention-acp",
          stationID: "station",
          kind: .acpDecision,
          severity: .critical,
          title: "Permission requested",
          subtitle: "Codex needs approval.",
          updatedAt: now.addingTimeInterval(-5)
        )
      ],
      sessions: [],
      reviews: [],
      commands: [
        MobileCommandRecord(
          id: "command-merge",
          stationID: "station",
          kind: .pullRequestMerge,
          risk: .destructive,
          status: .failed,
          title: "Merge PR",
          confirmationText: "Merge PR #812.",
          auditReason: "Reviewed from iPhone.",
          target: MobileCommandTarget(stationID: "station", targetRevision: 4),
          actorDeviceID: "device-phone",
          createdAt: now.addingTimeInterval(-30),
          expiresAt: now.addingTimeInterval(300),
          updatedAt: now.addingTimeInterval(-10),
          receipt: MobileCommandReceipt(
            commandID: "command-merge",
            stationID: "station",
            status: .failed,
            message: "Fresh-state validation failed.",
            receivedAt: now.addingTimeInterval(-12),
            completedAt: now.addingTimeInterval(-10),
            executionRevision: 4
          )
        )
      ]
    )

    let requests = MobileNotificationPlanner.requests(
      previous: previous,
      next: next,
      settings: .smartDefaults
    )

    XCTAssertEqual(
      requests.map(\.category),
      [.criticalDecision, .commandFailure, .stationHealth]
    )
    XCTAssertTrue(requests.contains { $0.title == "Permission requested" })
    XCTAssertTrue(requests.contains { $0.body == "Fresh-state validation failed." })
  }

  func testPlannerSuppressesUnchangedEventsAndDisabledCategories() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let snapshot = MobileDemoFixtures.snapshot(now: now)
    var settings = MobileNotificationSettings.smartDefaults
    settings.setEnabled(false, for: .needsYou)
    settings.setEnabled(false, for: .criticalDecision)
    settings.setEnabled(false, for: .stationHealth)
    settings.setEnabled(false, for: .commandFailure)

    let unchanged = MobileNotificationPlanner.requests(
      previous: snapshot,
      next: snapshot,
      settings: settings
    )
    let firstSeen = MobileNotificationPlanner.requests(
      previous: nil,
      next: snapshot,
      settings: settings
    )

    XCTAssertEqual(unchanged, [])
    XCTAssertEqual(firstSeen.map(\.category), [.commandStatus])
  }

  func testDeliveryHistoryFiltersAlreadyRecordedRequests() throws {
    let suiteName = "MobileNotificationDeliveryHistoryTests-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { UserDefaults().removePersistentDomain(forName: suiteName) }
    let history = MobileNotificationDeliveryHistory(userDefaults: defaults)
    let request = MobileNotificationRequest(
      id: "request-1",
      category: .needsYou,
      stationID: "station",
      title: "Needs You",
      body: "Review waiting.",
      interruption: .active,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    XCTAssertEqual(history.unrecordedRequests([request]), [request])
    XCTAssertEqual(history.unrecordedRequests([request]), [request])

    history.recordDeliveredRequestIDs([request.id])

    XCTAssertEqual(history.unrecordedRequests([request]), [])
  }
}
