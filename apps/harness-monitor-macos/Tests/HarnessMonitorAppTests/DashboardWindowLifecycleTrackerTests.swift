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

  func testFlushPersistsOpenState() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    tracker.markOpen()

    tracker.flushOpenAtQuit()

    XCTAssertTrue(
      DashboardWindowLifecycleTracker.wasOpenAtQuit(userDefaults: userDefaults)
    )
  }

  func testFlushPersistsClosedState() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    tracker.markOpen()
    tracker.flushOpenAtQuit()
    tracker.markClosed()

    tracker.flushOpenAtQuit()

    XCTAssertFalse(
      DashboardWindowLifecycleTracker.wasOpenAtQuit(userDefaults: userDefaults)
    )
  }

  func testWasOpenAtQuitDefaultsToFalseWithoutAValue() {
    XCTAssertFalse(
      DashboardWindowLifecycleTracker.wasOpenAtQuit(userDefaults: userDefaults)
    )
  }

  func testFlushReflectsLatestInMemoryStateRegardlessOfPriorWrite() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    userDefaults.set(true, forKey: DashboardWindowLifecycleTracker.openAtQuitKey)

    tracker.markClosed()
    tracker.flushOpenAtQuit()

    XCTAssertFalse(
      DashboardWindowLifecycleTracker.wasOpenAtQuit(userDefaults: userDefaults)
    )
  }
}
