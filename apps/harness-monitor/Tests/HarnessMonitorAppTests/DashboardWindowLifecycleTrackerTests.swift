import Foundation
import XCTest

@testable import HarnessMonitor

@MainActor
final class DashboardWindowLifecycleTrackerTests: XCTestCase {
  private var userDefaults: UserDefaults!
  private let suiteName = "io.harnessmonitor.tests.DashboardWindowLifecycleTracker"

  override func setUp() async throws {
    try await super.setUp()
    userDefaults = UserDefaults(suiteName: suiteName)
    userDefaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() async throws {
    userDefaults.removePersistentDomain(forName: suiteName)
    userDefaults = nil
    try await super.tearDown()
  }

  func testRestoreStateIsAbsentBeforeFirstSnapshot() {
    XCTAssertNil(
      DashboardWindowLifecycleTracker.restoreStateAtQuit(userDefaults: userDefaults)
    )
  }

  func testFlushPersistsOpenState() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    tracker.markOpen()

    tracker.flushOpenAtQuit()

    XCTAssertEqual(
      DashboardWindowLifecycleTracker.restoreStateAtQuit(userDefaults: userDefaults),
      true
    )
  }

  func testFlushPersistsClosedState() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    tracker.markOpen()
    tracker.flushOpenAtQuit()
    tracker.markClosed()

    tracker.flushOpenAtQuit()

    XCTAssertEqual(
      DashboardWindowLifecycleTracker.restoreStateAtQuit(userDefaults: userDefaults),
      false
    )
  }

  func testMigrationRemovesLegacySessionRestorationDefaultsIdempotently() {
    let migration = SessionWindowRestorationDefaultsMigration.self
    userDefaults.set(true, forKey: migration.bridgeFallbackKey)
    userDefaults.set(["session-a"], forKey: migration.tabbedSessionIDsKey)
    userDefaults.set(true, forKey: migration.dashboardWasForegroundTabKey)

    migration.run(userDefaults: userDefaults)
    migration.run(userDefaults: userDefaults)

    XCTAssertNil(userDefaults.object(forKey: migration.bridgeFallbackKey))
    XCTAssertNil(userDefaults.object(forKey: migration.tabbedSessionIDsKey))
    XCTAssertNil(userDefaults.object(forKey: migration.dashboardWasForegroundTabKey))
  }

  func testFlushAlsoRemovesLegacySessionRestorationDefaults() {
    let migration = SessionWindowRestorationDefaultsMigration.self
    userDefaults.set(["session-a"], forKey: migration.tabbedSessionIDsKey)
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)

    tracker.flushOpenAtQuit()

    XCTAssertNil(userDefaults.object(forKey: migration.tabbedSessionIDsKey))
  }
}
