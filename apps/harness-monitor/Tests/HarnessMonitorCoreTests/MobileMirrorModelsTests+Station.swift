import Foundation
import HarnessMonitorCore
import XCTest

extension MobileMirrorModelsTests {
  func testStationSnapshotMergeRefreshesOneStationWithoutDroppingOthers() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let base = makeStationMergeBaseSnapshot(now: now)
    let refreshed = makeStationMergeRefreshedSnapshot(now: now)

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

  private func makeStationMergeBaseSnapshot(now: Date) -> MobileMirrorSnapshot {
    MobileMirrorSnapshot(
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
  }

  private func makeStationMergeRefreshedSnapshot(now: Date) -> MobileMirrorSnapshot {
    MobileMirrorSnapshot(
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
  }
}
