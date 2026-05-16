import AppKit
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

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

  func testFlushPersistsTabbedSessionIDsAndDashboardForegroundState() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    let dashboardWindow = makeWindow(origin: .zero)
    let sessionA = makeWindow(origin: NSPoint(x: 24, y: 24))
    let sessionB = makeWindow(origin: NSPoint(x: 48, y: 48))
    defer { cleanUp([dashboardWindow, sessionA, sessionB]) }

    tracker.markOpen()
    prepareTabIdentity(dashboardWindow, toolbarID: "dashboard")
    prepareTabIdentity(sessionA, toolbarID: "session-a")
    prepareTabIdentity(sessionB, toolbarID: "session-b")
    show([dashboardWindow, sessionA, sessionB])
    dashboardWindow.addTabbedWindow(sessionA, ordered: .above)
    dashboardWindow.addTabbedWindow(sessionB, ordered: .above)
    dashboardWindow.tabGroup?.selectedWindow = dashboardWindow

    tracker.flushOpenAtQuit(
      dashboardWindow: dashboardWindow,
      sessionBindings: [
        (window: sessionA, sessionID: "sess-a"),
        (window: sessionB, sessionID: "sess-b"),
      ]
    )

    let expectedSessionIDs: [String] = dashboardWindow.tabGroup?.windows.compactMap { window -> String? in
      switch window {
      case sessionA:
        "sess-a"
      case sessionB:
        "sess-b"
      default:
        nil
      }
    } ?? []

    XCTAssertEqual(
      DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(userDefaults: userDefaults),
      .init(sessionIDs: expectedSessionIDs, wasForegroundTab: true)
    )
  }

  func testFlushClearsDashboardTabStateWhenDashboardIsStandalone() {
    let tracker = DashboardWindowLifecycleTracker(userDefaults: userDefaults)
    let dashboardWindow = makeWindow(origin: .zero)
    defer { cleanUp([dashboardWindow]) }

    tracker.markOpen()
    prepareTabIdentity(dashboardWindow, toolbarID: "dashboard")
    show([dashboardWindow])

    tracker.flushOpenAtQuit(
      dashboardWindow: dashboardWindow,
      sessionBindings: []
    )

    XCTAssertEqual(
      DashboardWindowLifecycleTracker.tabRestoreStateAtQuit(userDefaults: userDefaults),
      .empty
    )
  }

  private func makeWindow(origin: NSPoint) -> NSWindow {
    NSWindow(
      contentRect: .init(origin: origin, size: .init(width: 480, height: 320)),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
  }

  private func prepareTabIdentity(_ window: NSWindow, toolbarID: String) {
    window.toolbar = NSToolbar(identifier: toolbarID)
    SessionWindowTabbingSupport.prepareWindowForTabbing(window, preference: .always)
  }

  private func show(_ windows: [NSWindow]) {
    for window in windows.dropLast() {
      window.orderFront(nil)
    }
    windows.last?.makeKeyAndOrderFront(nil)
  }

  private func cleanUp(_ windows: [NSWindow]) {
    for window in windows.reversed() {
      window.orderOut(nil)
    }
  }
}
