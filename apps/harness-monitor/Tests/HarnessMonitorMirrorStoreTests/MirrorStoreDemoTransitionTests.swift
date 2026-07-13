import Foundation
import HarnessMonitorCore
import HarnessMonitorMirrorStore
import XCTest

@MainActor
final class MirrorStoreDemoTransitionTests: XCTestCase {
  func testDisablingDemoModeClearsPersistedDemoSnapshot() async throws {
    let snapshotURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("mirror-store-demo-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: snapshotURL) }

    let sharedStore = MobileSharedSnapshotStore(fileURL: snapshotURL)
    let store = MirrorStore(
      demoModeEnabled: true,
      sharedSnapshotStore: sharedStore
    )
    await store.refresh()
    XCTAssertFalse(store.snapshot.stations.isEmpty)
    XCTAssertFalse(try XCTUnwrap(sharedStore.loadLatestSnapshot()).stations.isEmpty)

    store.setDemoMode(false)

    XCTAssertFalse(store.demoModeEnabled)
    XCTAssertEqual(store.presentedSyncStatus, .unpaired)
    XCTAssertTrue(store.snapshot.stations.isEmpty)
    XCTAssertEqual(store.selectedStationID, "")
    XCTAssertTrue(try XCTUnwrap(sharedStore.loadLatestSnapshot()).stations.isEmpty)

    await store.refresh()
    XCTAssertEqual(store.syncStatus, .unpaired)
    XCTAssertTrue(store.snapshot.stations.isEmpty)
  }
}
