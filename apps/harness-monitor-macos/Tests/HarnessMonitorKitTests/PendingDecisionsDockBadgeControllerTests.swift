import AppKit
import XCTest

@testable import HarnessMonitorKit

@MainActor
final class PendingDecisionsDockBadgeControllerTests: XCTestCase {
  func testBadgeLabelFormatting() {
    XCTAssertNil(PendingDecisionsDockBadgeController.badgeLabel(for: 0))
    XCTAssertNil(PendingDecisionsDockBadgeController.badgeLabel(for: -1))
    XCTAssertEqual(PendingDecisionsDockBadgeController.badgeLabel(for: 3), "3")
  }

  func testSyncUpdatesDockTileOnlyWhenValueChanges() {
    let dockTile = TestDockTile()
    let controller = PendingDecisionsDockBadgeController(dockTile: dockTile)

    controller.sync(count: 2)
    XCTAssertEqual(dockTile.badgeLabel, "2")
    XCTAssertEqual(dockTile.displayCallCount, 1)

    controller.sync(count: 2)
    XCTAssertEqual(dockTile.displayCallCount, 1)

    controller.sync(count: 0)
    XCTAssertNil(dockTile.badgeLabel)
    XCTAssertEqual(dockTile.displayCallCount, 2)
  }

  func testSyncNoOpsWhenDockTileIsUnavailable() {
    let controller = PendingDecisionsDockBadgeController(dockTileProvider: { nil })

    controller.sync(count: 2)
  }
}

private final class TestDockTile: DockTileBadgeWriting {
  var badgeLabel: String?
  private(set) var displayCallCount = 0

  func display() {
    displayCallCount += 1
  }
}
