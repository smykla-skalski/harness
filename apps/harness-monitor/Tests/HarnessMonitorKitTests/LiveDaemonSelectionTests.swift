import Foundation
import XCTest

@testable import HarnessMonitorKit

final class LiveDaemonSelectionTests: XCTestCase {
  private func candidate(_ path: String, pid: Int32, startedAt: String) -> LiveDaemonCandidate {
    LiveDaemonCandidate(dataHomeRoot: URL(fileURLWithPath: path), pid: pid, startedAt: startedAt)
  }

  func testPrefersBaseDaemonOverNewerLaneDaemon() {
    let base = candidate("/base", pid: 100, startedAt: "2026-05-26T10:00:00Z")
    let lane = candidate("/lane", pid: 200, startedAt: "2026-05-26T12:00:00Z")
    let chosen = HarnessMonitorPaths.chooseLiveDaemon(base: base, lanes: [lane])
    XCTAssertEqual(
      chosen,
      base,
      "the stable base-container daemon must win over a newer transient lane daemon"
    )
  }

  func testFallsBackToNewestLaneWhenNoBaseDaemon() {
    let older = candidate("/laneA", pid: 1, startedAt: "2026-05-26T10:00:00Z")
    let newer = candidate("/laneB", pid: 2, startedAt: "2026-05-26T12:00:00Z")
    let chosen = HarnessMonitorPaths.chooseLiveDaemon(base: nil, lanes: [older, newer])
    XCTAssertEqual(chosen, newer, "with no base daemon, the newest live lane daemon wins")
  }

  func testReturnsNilWhenNoLiveCandidates() {
    XCTAssertNil(HarnessMonitorPaths.chooseLiveDaemon(base: nil, lanes: []))
  }
}
