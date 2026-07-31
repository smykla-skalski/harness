import Foundation
import XCTest

@testable import HarnessMonitorKit

/// A `task_board_updated` push carries only a revision and scopes, never the
/// changed rows, so every push makes the store refetch and re-decode the whole
/// board. A sync that touches dozens of items therefore emits dozens of pushes,
/// and the 50 ms coalescing window is far shorter than one refresh, so the
/// refreshes used to chain back to back for the length of the sync.
final class TaskBoardItemsRefreshPacingTests: XCTestCase {
  private let minimumInterval: TimeInterval = 1
  private let start = Date(timeIntervalSince1970: 1_700_000_000)

  private func delay(lastRefreshAt: Date?, now: Date) -> TimeInterval {
    TaskBoardItemsRefreshPacing.delay(
      lastRefreshAt: lastRefreshAt,
      now: now,
      minimumInterval: minimumInterval
    )
  }

  func testFirstRefreshIsNotDelayed() {
    XCTAssertEqual(delay(lastRefreshAt: nil, now: start), 0)
  }

  func testRefreshAfterTheMinimumIntervalIsNotDelayed() {
    XCTAssertEqual(
      delay(lastRefreshAt: start, now: start.addingTimeInterval(1)),
      0
    )
    XCTAssertEqual(
      delay(lastRefreshAt: start, now: start.addingTimeInterval(30)),
      0
    )
  }

  func testBurstRefreshWaitsOutTheRemainder() {
    XCTAssertEqual(
      delay(lastRefreshAt: start, now: start.addingTimeInterval(0.2)),
      0.8,
      accuracy: 0.0001
    )
  }

  /// A clock that jumped backwards must not park the board refresh forever.
  func testClockGoingBackwardsDoesNotStall() {
    XCTAssertEqual(
      delay(lastRefreshAt: start, now: start.addingTimeInterval(-500)),
      0
    )
  }
}
