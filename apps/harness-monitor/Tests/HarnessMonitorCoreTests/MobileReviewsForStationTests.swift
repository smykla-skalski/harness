import Foundation
import HarnessMonitorCore
import XCTest

final class MobileReviewsForStationTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 2_000_000)

  private func review(
    _ id: String,
    stationID: String,
    needsYou: Bool,
    updatedAt: Date
  ) -> MobileReviewSummary {
    MobileReviewSummary(
      id: id,
      stationID: stationID,
      repository: "harness",
      number: 1,
      title: id,
      author: "bart",
      state: "open",
      checksSummary: "pending",
      needsYou: needsYou,
      updatedAt: updatedAt
    )
  }

  private func snapshot(_ reviews: [MobileReviewSummary]) -> MobileMirrorSnapshot {
    MobileMirrorSnapshot(
      revision: 1,
      generatedAt: now,
      expiresAt: now.addingTimeInterval(60),
      stations: [],
      attention: [],
      sessions: [],
      reviews: reviews,
      taskBoardItems: [],
      commands: []
    )
  }

  func testFiltersToSelectedStation() {
    let snap = snapshot([
      review("a", stationID: "station-a", needsYou: true, updatedAt: now),
      review("b", stationID: "station-b", needsYou: true, updatedAt: now),
    ])
    XCTAssertEqual(snap.reviews(forStation: "station-a").map(\.id), ["a"])
  }

  func testEmptyStationIncludesEveryStation() {
    let snap = snapshot([
      review("a", stationID: "station-a", needsYou: true, updatedAt: now),
      review("b", stationID: "station-b", needsYou: true, updatedAt: now),
    ])
    XCTAssertEqual(Set(snap.reviews(forStation: "").map(\.id)), ["a", "b"])
  }

  func testNeedsYouOrderedBeforeOthersThenByRecency() {
    let older = now
    let newer = now.addingTimeInterval(3600)
    let snap = snapshot([
      review("stale-needs-you", stationID: "station-a", needsYou: true, updatedAt: older),
      review("recent-activity", stationID: "station-a", needsYou: false, updatedAt: newer),
      review("recent-needs-you", stationID: "station-a", needsYou: true, updatedAt: newer),
    ])
    XCTAssertEqual(
      snap.reviews(forStation: "station-a").map(\.id),
      ["recent-needs-you", "stale-needs-you", "recent-activity"]
    )
  }
}
